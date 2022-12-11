// Copyright(c) 2022-present, Anton Lilja.
// Distributed under the MIT License (http://opensource.org/licenses/MIT)

const std = @import("std");

pub const ReservedMemoryEntry = extern struct {
    address: usize = 0,
    size: usize = 0,
};

fn Parser(comptime paths: anytype) type {
    return struct {
        const Self = @This();

        const Token = enum(u32) {
            begin_node = 0x00000001,
            end_node = 0x00000002,
            prop = 0x00000003,
            nop = 0x00000004,
            end = 0x00000009,
        };

        const Prop = extern struct {
            len: u32,
            name_off: u32,
        };

        tree_address: usize,
        strings_start: usize,

        address_cells: u32 = 2,
        size_cells: u32 = 1,

        /// Get token from aligned address and increment address by token size
        fn getToken(self: *Self) Token {
            self.tree_address = std.mem.alignForward(self.tree_address, @sizeOf(u32));
            const token = @intToEnum(Token, std.mem.bigToNative(u32, @intToPtr(*u32, self.tree_address).*));
            self.tree_address += @sizeOf(u32);
            return token;
        }

        /// Get prop and increment address by its size and the value length
        fn getProp(self: *Self) *Prop {
            const prop = @intToPtr(*Prop, self.tree_address);
            self.tree_address += @sizeOf(Prop);
            self.tree_address += std.mem.bigToNative(u32, prop.len);
            return prop;
        }

        /// Get name of prop
        fn getPropName(self: *const Self, prop: *const Prop) []const u8 {
            return std.mem.span(@intToPtr([*:0]u8, self.strings_start + std.mem.bigToNative(u32, prop.name_off)));
        }

        /// Get value of prop
        fn getPropValue(comptime DestType: type, prop: *const Prop) DestType {
            return @intToPtr(*DestType, @ptrToInt(prop) + @sizeOf(Prop)).*;
        }

        /// Get name of node and increment address by the names length
        fn getNodeName(self: *Self) []const u8 {
            const name = std.mem.span(@intToPtr([*:0]u8, self.tree_address));
            self.tree_address += name.len + 1;
            return name;
        }

        /// Get node name without "@unit-address"
        fn getSearchName(name: []const u8) []const u8 {
            return if (std.mem.indexOfScalar(u8, name, '@')) |index| name[0..index] else name;
        }

        /// Check if node or prop is continutation of parent path
        fn pathContinuation(
            parent_path: []const u8,
            potential_path: []const u8,
            name: []const u8,
        ) ?[]const u8 {
            // The resulting length of the new path is shorter than the length of the potential path
            if (parent_path.len + name.len > potential_path.len) return null;

            // The parent path matches the potential path up until the length of the parent path
            if (!std.mem.eql(u8, parent_path, potential_path[0..parent_path.len])) return null;

            // The name matches the next part of the potential path
            if (!std.mem.eql(u8, potential_path[parent_path.len..(parent_path.len + name.len)], name)) return null;

            // Check if node or prop
            if (parent_path.len + name.len + 1 < potential_path.len) {
                // Node
                return potential_path[0..(parent_path.len + name.len + 1)];
            } else {
                // Prop
                return potential_path[0..(parent_path.len + name.len)];
            }
        }

        /// Parses node and it's children without getting any props, values or names
        fn parseUnknownNode(self: *Self) void {
            while (true) {
                const token = self.getToken();
                switch (token) {
                    .begin_node => {
                        _ = self.getNodeName();
                        self.parseUnknownNode();
                    },
                    .prop => _ = self.getProp(),
                    .end_node => break,
                    .nop => {},
                    .end => unreachable,
                }
            }
        }

        /// Parses node and all of its children while looking for requested props
        fn parseNode(self: *Self, parent_path: []const u8) void {
            outer: while (true) {
                const token = self.getToken();
                switch (token) {
                    .begin_node => {
                        const name = self.getNodeName();
                        const search_name = getSearchName(name);

                        // Loop through all paths and look for possible continutaion of parent path
                        inline for (paths) |path| {
                            if (pathContinuation(parent_path, path.path, search_name)) |new_path| {

                                // Save address and size cells
                                const old_address_cells = self.address_cells;
                                const old_size_cells = self.size_cells;

                                self.parseNode(new_path);

                                // Restore old address and size cells
                                self.address_cells = old_address_cells;
                                self.size_cells = old_size_cells;
                                continue :outer;
                            }
                        }

                        // If node is unknown parse it and all of its children
                        // without getting any values or names
                        self.parseUnknownNode();
                    },
                    .prop => {
                        const prop = self.getProp();
                        const name = self.getPropName(prop);

                        // Always handle address-cells and size-cells props
                        if (std.mem.eql(u8, name, "#address-cells")) {
                            self.address_cells = std.mem.bigToNative(u32, getPropValue(u32, prop));
                        } else if (std.mem.eql(u8, name, "#size-cells")) {
                            self.size_cells = std.mem.bigToNative(u32, getPropValue(u32, prop));
                        }

                        // Loop through all paths and look for prop which lies under the parent path
                        inline for (paths) |path| {
                            if (pathContinuation(parent_path, path.path, name)) |new_path| {
                                path.callback(
                                    new_path,
                                    name,
                                    @ptrToInt(prop) + @sizeOf(Prop),
                                    std.mem.bigToNative(u32, prop.len),
                                    self.address_cells,
                                    self.size_cells,
                                );
                                continue :outer;
                            }
                        }
                    },
                    .nop => {},
                    .end_node => break,
                    .end => break,
                }
            }
        }

        pub fn parseRoot(self: *Self) void {
            const root_token = self.getToken();
            std.debug.assert(root_token == .begin_node);

            // Skip null byte for empty root name
            self.tree_address += 1;

            // Parse children with parent path set to ""
            self.parseNode("");
        }
    };
}

/// Parses the FDT calling relevent callback functions and returning slice of reserved memory regions
pub fn parseFDT(comptime last_comp_version: u32, fdt_address: usize, comptime structs_paths: anytype) ![]const ReservedMemoryEntry {
    const FDTHeader = extern struct {
        magic: u32,
        total_size: u32,
        off_dt_struct: u32,
        off_dt_strings: u32,
        off_mem_rsvmap: u32,
        version: u32,
        last_comp_version: u32,
        boot_cpuid_phys: u32,
        size_dt_strings: u32,
        size_dt_struct: u32,
    };

    const fdt = @intToPtr(*FDTHeader, fdt_address);

    // Validate header
    if (std.mem.bigToNative(u32, fdt.magic) != 0xd00dfeed) return error.InvalidMagic;
    if (std.mem.bigToNative(u32, fdt.last_comp_version) != last_comp_version) return error.IncompatibleVersion;

    // Get size of reserved memory
    const reserved_memory = blk: {
        const reserved_memory = @intToPtr([*]ReservedMemoryEntry, @ptrToInt(fdt) + std.mem.bigToNative(u32, fdt.off_mem_rsvmap));
        var i: usize = 0;
        while (!(reserved_memory[i].address == 0 and reserved_memory[i].size == 0)) : (i += 1) {}

        break :blk reserved_memory[0..i];
    };

    // Parse structs
    const structs_start = fdt_address + std.mem.bigToNative(u32, fdt.off_dt_struct);
    const strings_start = fdt_address + std.mem.bigToNative(u32, fdt.off_dt_strings);
    var parser = Parser(structs_paths){
        .tree_address = structs_start,
        .strings_start = strings_start,
    };
    parser.parseRoot();

    return reserved_memory;
}
