const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("oilzio", "src/qsn.zig");
    lib.setBuildMode(mode);
    lib.install();

    var qsn_tests = b.addTest("src/qsn.zig");
    qsn_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&qsn_tests.step);
}
