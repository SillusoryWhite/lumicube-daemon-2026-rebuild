/*
 * Copyright (c) 2022 Abstract Foundry Limited
 */

package com.abstractfoundry.daemon.python.service;

import com.abstractfoundry.daemon.common.LineReaderTask;
import com.abstractfoundry.daemon.common.Resources;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.SocketChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.locks.LockSupport;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class GlobalPythonService {

	private static final Logger logger = LoggerFactory.getLogger(GlobalPythonService.class);

	private static final String CONTEXT_PREFIX = "foundry-global-service-context-";

	private final ExecutorService globalPool;
	private final UnixDomainSocketAddress address;
	private final ObjectMapper objectMapper;

	private Path contextDirectory;
	private Process process;

	public GlobalPythonService(ExecutorService globalPool, Path path) {
		this.globalPool = globalPool;
		this.address = UnixDomainSocketAddress.of(path);
		this.objectMapper = new ObjectMapper();
	}

	public int interruptExecutingMethods() {
		try {
			var response = post("interrupt_executing_methods", Map.of());
			var phase = response.get("phase");
			if (phase instanceof Number number) {
				return number.intValue();
			}
			throw new RuntimeException("Unexpected response from the global Python service: " + response);
		} catch (IOException | RuntimeException exception) {
			logger.error("Error interrupting executing methods.", exception);
			return -1;
		}
	}

	public Object invokeModuleMethod(CharSequence moduleNameView, CharSequence methodNameView, CharSequence jsonView) {
		Map invocation = new HashMap();
		invocation.put("module", moduleNameView.toString());
		invocation.put("method", methodNameView.toString());
		invocation.put("json", jsonView.toString()); // TODO: Don't nest JSON as a string?
		try {
			var response = post("invoke_module_method", invocation);
			if (!response.containsKey("result")) {
				logger.error("Error invoking method: " + response);
				if (!response.containsKey("error")) {
					throw new RuntimeException("Error invoking method.");
				} else {
					throw new RuntimeException((String) response.get("error"));
				}
			} else {
				return response.get("result");
			}
		} catch (IOException exception) {
			logger.error("I/O error invoking method.", exception);
			throw new RuntimeException("Error invoking method.", exception);
		}
	}

	/**
	 * Sends a JSON POST request to the given path of the global Python service over the Unix domain
	 * socket, using a minimal HTTP/1.1 client built on java.net Unix domain sockets (this avoids the
	 * JAX-RS/Jersey/Jetty client version compatibility issues on newer JDKs).
	 */
	private Map<String, Object> post(String path, Map<String, Object> payload) throws IOException {
		var body = objectMapper.writeValueAsString(payload).getBytes(StandardCharsets.UTF_8);
		var request = new StringBuilder()
			.append("POST /").append(path).append(" HTTP/1.1\r\n")
			.append("Host: localhost\r\n")
			.append("Content-Type: application/json\r\n")
			.append("Content-Length: ").append(body.length).append("\r\n")
			.append("Connection: close\r\n")
			.append("\r\n")
			.toString()
			.getBytes(StandardCharsets.US_ASCII);
		var responseBytes = new java.io.ByteArrayOutputStream();
		try (var channel = SocketChannel.open(StandardProtocolFamily.UNIX)) {
			channel.connect(address);
			var requestBuffer = ByteBuffer.allocate(request.length + body.length);
			requestBuffer.put(request);
			requestBuffer.put(body);
			requestBuffer.flip();
			while (requestBuffer.hasRemaining()) {
				channel.write(requestBuffer);
			}
			var readBuffer = ByteBuffer.allocate(8192);
			while (channel.read(readBuffer) != -1) {
				readBuffer.flip();
				responseBytes.write(readBuffer.array(), 0, readBuffer.remaining());
				readBuffer.clear();
			}
		}
		var responseText = responseBytes.toString(StandardCharsets.UTF_8);
		var headerEnd = responseText.indexOf("\r\n\r\n");
		if (headerEnd < 0) {
			throw new IOException("Malformed HTTP response from the global Python service.");
		}
		var statusLine = responseText.substring(0, responseText.indexOf("\r\n"));
		var statusCode = Integer.parseInt(statusLine.split(" ")[1]);
		var json = responseText.substring(headerEnd + 4);
		if (statusCode != 200) {
			throw new IOException("Unexpected HTTP status from the global Python service: " + statusCode + " (" + json + ").");
		}
		return objectMapper.readValue(json, new TypeReference<Map<String, Object>>() { });
	}

	public void start() throws IOException {
		contextDirectory = Files.createTempDirectory(CONTEXT_PREFIX);
		Resources.extract(Path.of("python", "global_service"), contextDirectory.resolve("global_service"),
			"__init__.py", // Note: Sadly Java doesn't allow enumeration of resource files, so we must list them explicitly.
			"service.py"
		);
		Resources.extract(Path.of("python", "foundry_api"), contextDirectory.resolve("foundry_api"),
			"__init__.py", // Note: Sadly Java doesn't allow enumeration of resource files, so we must list them explicitly.
			"standard_library.py"
		);
		Resources.extract(Path.of("python", "fonts"), contextDirectory.resolve("fonts"),
			"slkscr.ttf"
		);

		var builder = new ProcessBuilder(
			"/usr/bin/python3", "-c", "import global_service; global_service.start()", contextDirectory.toString()
		);
		var environment = builder.environment();
		environment.put("PYTHONPATH", contextDirectory.toString());
		builder.directory(contextDirectory.toFile());
		process = builder.start();
		globalPool.submit(new LineReaderTask(process.getInputStream(), line -> logger.warn("{}.", line)));
		globalPool.submit(new LineReaderTask(process.getErrorStream(), line -> logger.error("{}.", line)));

		Exception cause = null;
		for (var attempt = 0; attempt < 5; attempt++) {
			try {
				var response = post("ping", Map.of("value", 123));
				if (response.get("result").equals(123)) {
					return;
				}
			} catch (RuntimeException | IOException exception) {
				cause = exception;
			}
			LockSupport.parkNanos(1_000_000_000L);
		}
		if (cause != null) {
			logger.error("Failed to connect to service.", cause);
		} else {
			logger.error("Failed to connect to service.");
		}
	}

	public void stop() {
		// Note: Nothing to stop; the process is terminated by the daemon's finally block.
	}

}
