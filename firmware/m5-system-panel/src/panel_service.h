// Constants shared with the companion. Keep this file free of Arduino and M5
// headers so that it can be compiled and checked on the Mac as well.
#pragma once

// The Bonjour service name (RFC 6335 §5.1: at most 15 characters — this one is
// exactly 15). The companion's PanelService.name and the NSBonjourServices entry
// in Info.plist carry the same string; ServiceNameTests on the Mac side fails
// if this file disagrees.
#define PANEL_SERVICE_NAME "m5-system-panel"

// The TCP port of both sessions (protocol v1 §2, §5.1).
#define PANEL_PORT 47110

// Filled in by the Makefile from `git describe`; "dev" for a build made outside it.
#ifndef FW_VERSION
#define FW_VERSION "dev"
#endif
