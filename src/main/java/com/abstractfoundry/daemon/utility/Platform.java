/*
 * Copyright (c) 2022 Abstract Foundry Limited
 */

package com.abstractfoundry.daemon.utility;

public class Platform {

	public static String getCanonicalName() {
		// Note: aarch64 / arm64 are 64-bit ARM platforms (e.g. Raspberry Pi with a 64-bit OS).
		// The original check "contains(\"arm\")" fails for "aarch64", which would wrongly map it to "x64".
		var arch = System.getProperty("os.arch").toLowerCase();
		return arch.contains("arm") || arch.startsWith("aarch64") || "arm64".equals(arch) ? "arm" : "x64"; // TODO: Make generic.
	}

}
