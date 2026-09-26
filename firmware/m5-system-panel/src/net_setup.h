// Setup mode (protocol v1 §5): scan, then the setup SoftAP with a one-time
// password, then one setup session at a time. Returns only by restarting.
#pragma once

namespace net_setup {

[[noreturn]] void run();

}  // namespace net_setup
