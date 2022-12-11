# zig-fdt

An [FDT (DTB)](https://devicetree-specification.readthedocs.io/en/stable/index.html) parser for zig.

## Examples
Callbacks will be called when the parser finds a requested property (for example reg under cpus/cpu/).
```zig
    const fdt = @import("fdt.zig");

    fn parseHartReg(
        path: []const u8,
        name: []const u8,
        value_address: usize,
        value_len: u32,
        address_cells: u32,
        size_cells: u32,
    ) void {
        ...
    }

    fn someFunc() void {
        ...
        const reserved_memory = fdt.parseFDT(16, fdt_address, .{
            .{ .path = "cpus/cpu/reg", .callback = parseHartReg },
        }) catch @panic("Invalid FDT header");
        ...
    }
```

## TODO
* Provide tests for struct parser
