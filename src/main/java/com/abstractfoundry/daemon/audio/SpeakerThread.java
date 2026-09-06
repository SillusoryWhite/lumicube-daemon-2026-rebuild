/*
 * Copyright (c) 2022 Abstract Foundry Limited
 */

package com.abstractfoundry.daemon.audio;

import com.abstractfoundry.daemon.store.Store;
import com.abstractfoundry.daemon.bus.FlatDictionary;
import com.abstractfoundry.daemon.bus.Metadata;
import com.abstractfoundry.daemon.uavcan.BackoffException;
import com.abstractfoundry.daemon.uavcan.Node;
import com.abstractfoundry.daemon.uavcan.NullContinuation;
import com.abstractfoundry.daemon.uavcan.TypeId;
import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.locks.LockSupport;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public class SpeakerThread extends Thread {

	private static final Logger logger = LoggerFactory.getLogger(SpeakerThread.class);

	// TODO: We should really create a new output device inside PulseAudio, rather than monitoring the default, either making it the default, or at least having out methods target our device explicitly by name.

	private static final int BATCH_CAPACITY = 112; // TODO: Eventually we should take this parameter from the metadata.
	private static final int BATCH_COUNT = 3;
	private static final int VOLUME_REDUCTION = 1; // TODO: Set back to 1.

	private final Node daemonNode;
	private final Store store;
	private final int[] keys = new int[BATCH_CAPACITY];
	private final int[] samples = new int[BATCH_CAPACITY];
	private final ByteBuffer scratchpad = ByteBuffer.allocate(BATCH_CAPACITY * BATCH_COUNT * 2); // Format "s16le" uses two bytes of data per sample.
	private final ByteBuffer[] buffers = new ByteBuffer[BATCH_COUNT];

	private boolean emit = false;
	private int destinationId;
	private Metadata cachedMetadata = null;
	private int floorKey = -1;

	public SpeakerThread(Node daemonNode, Store store) {
		super("Foundry Speaker");
		this.daemonNode = daemonNode;
		this.store = store;
		scratchpad.order(ByteOrder.LITTLE_ENDIAN); // Format "s16le" use little-endian byte order.
		for (var index = 0; index < BATCH_COUNT; index++) {
			buffers[index] = ByteBuffer.allocate(256);
			buffers[index].order(ByteOrder.LITTLE_ENDIAN);
		}
	}

	@Override
	public void run() {
		try {
			LockSupport.parkNanos(2_000_000_000L); // Wait until the daemon has warmed-up a bit.
			var outputSinkName = ensureOutputSink();
			if (outputSinkName != null) {
				var outputSinkMonitorDeviceName = outputSinkName + ".monitor";
				logger.info("Monitoring audio sink: " + outputSinkMonitorDeviceName);
				monitorPulseAudioDevice(outputSinkMonitorDeviceName, "s16le", 1, 32000, scratchpad.capacity());
			}
		} catch (IOException exception) {
			logger.error("I/O exception in speaker thread.", exception);
		}
	}

	/**
	 * Ensures a dedicated PulseAudio/PipeWire null sink exists for relaying system playback audio to the
	 * LumiCube speaker, and makes it the default sink.
	 * <p>
	 * Using a dedicated sink (rather than monitoring the existing default sink) avoids an acoustic
	 * feedback loop: on systems where the only sink is the daemon's own virtual-microphone null sink,
	 * monitoring that sink would capture the cube's own microphone audio and play it straight back to
	 * the cube's speaker (howling). With a separate sink, only audio actually played to the system
	 * output (e.g. by ffplay) is relayed, and microphone audio never enters it.
	 */
	private String ensureOutputSink() throws IOException {
		var outputSinkName = "abstract_foundry.daemon.output.null_sink";
		var loaded = getPulseAudioSymbolicNames("sinks").contains(outputSinkName);
		if (!loaded) {
			loaded = loadPulseAudioModule("module-null-sink", "sink_name=" + outputSinkName, "sink_properties=device.description='AbstractFoundrySpeakerOutput'");
		}
		if (!loaded) {
			logger.error("Failed to create the dedicated speaker output sink: " + outputSinkName);
			return null;
		}
		if (!setPulseAudioDefaultSink(outputSinkName)) {
			logger.error("Failed to set the dedicated speaker output sink as default: " + outputSinkName);
		}
		return outputSinkName;
	}

	private boolean setPulseAudioDefaultSink(String name) throws IOException {
		var builder = new ProcessBuilder("/usr/bin/pactl", "set-default-sink", name)
			.redirectOutput(ProcessBuilder.Redirect.DISCARD); // Note: Directing the output stream ensures we don't deadlock, see: https://stackoverflow.com/a/57949752
		var process = builder.start();
		var raw = process.getErrorStream();
		try (var reader = new InputStreamReader(raw); var stream = new BufferedReader(reader)) {
			while (true) {
				var line = stream.readLine();
				if (line == null) {
					break;
				} else if (line.trim().length() > 0) {
					return false;
				}
			}
		}
		return true;
	}

	private boolean loadPulseAudioModule(String ...arguments) throws IOException {
		var command = new ArrayList<String>();
		var prefix = Arrays.asList("/usr/bin/pactl", "load-module");
		var suffix = Arrays.asList(arguments);
		command.addAll(prefix);
		command.addAll(suffix);
		var builder = new ProcessBuilder(command)
			.redirectOutput(ProcessBuilder.Redirect.DISCARD); // Note: Directing the output stream ensures we don't deadlock, see: https://stackoverflow.com/a/57949752
		var process = builder.start();
		var raw = process.getErrorStream();
		try (var reader = new InputStreamReader(raw); var stream = new BufferedReader(reader)) {
			while (true) {
				var line = stream.readLine();
				if (line == null) {
					break;
				} else if (line.trim().length() > 0) {
					return false;
				}
			}
		}
		return true;
	}

	private Set<String> getPulseAudioSymbolicNames(String kind) throws IOException {
		var result = new HashSet<String>();
		var builder = new ProcessBuilder("/usr/bin/pactl", "list", "short", kind)
			.redirectError(ProcessBuilder.Redirect.DISCARD); // Note: Directing the error stream ensures we don't deadlock, see: https://stackoverflow.com/a/57949752
		var process = builder.start();
		var raw = process.getInputStream();
		try (var reader = new InputStreamReader(raw); var stream = new BufferedReader(reader)) {
			while (true) {
				var line = stream.readLine();
				if (line == null) {
					break;
				}
				var values = line.split("\t");
				var name = values[1];
				result.add(name);
			}
		}
		return result;
	}

	private void monitorPulseAudioDevice(String name, String format, int channels, int rate, int latency) throws IOException {
		var builder = new ProcessBuilder("/usr/bin/pamon", "--device=" + name, "--format=" + format, "--channels=" + channels, "--rate=" + rate, "--latency=" + latency, "--client-name=AbstractFoundryDaemon")
			.redirectError(ProcessBuilder.Redirect.DISCARD); // Note: Directing the error stream ensures we don't deadlock, see: https://stackoverflow.com/a/57949752
		var process = builder.start();
		var raw = process.getInputStream();
		var continuation = new NullContinuation();
		try (var stream = new BufferedInputStream(raw)) {
			while (!Thread.interrupted()) {
				// (1) Read the raw data into the scratchpad.
				var read = scratchpad.capacity();
				stream.readNBytes(scratchpad.array(), 0, read);
				scratchpad.limit(read);
				scratchpad.position(0);
				if (!emit) {
					// (2) Attempt to fetch and cache the destination, metadata etc.
					var module = store.getNamespace().getModule("speaker");
					if (module != null) {
						destinationId = module.getId();
						cachedMetadata = module.getMetadata();
						floorKey = module.getKey("data");
						emit = true;
					} else {
						LockSupport.parkNanos(1_000_000_000L); // Wait for the speaker to become available.
					}
				}
				if (emit) {
					// (2.5) Track the peak level of the samples being relayed, so the web dashboard
					// can display a live audio-level chart for the speaker module (the speaker.data field
					// is otherwise never published back from the cube and would remain a flat line).
					var peak = 0;
					// (3) Serialise the batches.
					for (var batchNumber = 0; batchNumber < BATCH_COUNT; batchNumber++) {
						for (var index = 0; index < samples.length; index++) {
							keys[index] = index + floorKey;
							var sample = scratchpad.getShort() / VOLUME_REDUCTION;
							samples[index] = sample;
							var magnitude = Math.abs(sample);
							if (magnitude > peak) {
								peak = magnitude;
							}
						}
						var length = FlatDictionary.serialise(buffers[batchNumber].array(), 0, keys, samples, 0, samples.length, cachedMetadata);
						buffers[batchNumber].limit(length);
						buffers[batchNumber].position(0);
					}
					// Persist the speaker output level into the Store / RedisTimeSeries.
					store.putLatestFields(destinationId, new int[] { floorKey }, new int[] { peak }, 1);
					// (4) Make the request.
					final int requestPriority = 20; // TODO: Make configurable.
					try {
						daemonNode.request(destinationId, TypeId.SET_FIELDS, requestPriority, buffers, BATCH_COUNT, continuation);
					} catch (BackoffException exception) {
						logger.debug("Audio samples skipped due to backoff signal.");
					}
				}
			}
		}
	}

}
