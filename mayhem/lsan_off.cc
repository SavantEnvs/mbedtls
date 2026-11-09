// Disable LeakSanitizer at build time (ASan/UBSan stay active); linked into every fuzz binary.
extern "C" int __lsan_is_turned_off() { return 1; }
