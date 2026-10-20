//! This file defines the low(er)-level `get` method, returning `Data`.
const std = @import("std");

const FieldInfo = struct { name: [:0]const u8, type: type };

/// Comptime-only compat shim: newer Zig 0.17 dev snapshots removed
/// `std.meta.fields` and the `StructField` array in favor of flattened
/// `field_names` / `field_types` / `field_attrs`. This rebuilds a
/// name/type pair array for the sites that only need those two.
fn FieldsOf(comptime T: type) type {
    return [@typeInfo(T).@"struct".field_names.len]FieldInfo;
}

fn structFields(comptime T: type) FieldsOf(T) {
    const info = @typeInfo(T).@"struct";
    var tmp: [info.field_names.len]FieldInfo = undefined;
    for (info.field_names, info.field_types, 0..) |n, t, i| {
        tmp[i] = .{ .name = n, .type = t };
    }
    return tmp;
}

const tables_module = @import("tables");
const tables = tables_module.tables;

fn TableData(comptime Table: anytype) type {
    const DataSlice = if (@hasField(Table, "stage3"))
        @FieldType(Table, "stage3")
    else
        @FieldType(Table, "stage2");
    return @typeInfo(DataSlice).pointer.child;
}

fn tableInfoFor(comptime field: []const u8) struct { name: []const u8, type: type } {
    const info = @typeInfo(@TypeOf(tables)).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (@hasField(TableData(T), field)) {
            return .{ .name = name, .type = T };
        }
    }

    @compileError("Table not found for field: " ++ field);
}

pub fn hasField(comptime field: []const u8) bool {
    inline for (@typeInfo(@TypeOf(tables)).@"struct".field_types) |T| {
        if (@hasField(TableData(T), field)) {
            return true;
        }
    }

    return false;
}

fn BackingFor(comptime field: []const u8) type {
    return @FieldType(tables_module.Backing, field);
}

pub fn backingFor(comptime field: []const u8) BackingFor(field) {
    return @field(tables_module.backing, field);
}

fn TableFor(comptime field: []const u8) type {
    const tableInfo = tableInfoFor(field);
    return @FieldType(@TypeOf(tables), tableInfo.name);
}

fn tableFor(comptime field: []const u8) TableFor(field) {
    return @field(tables, tableInfoFor(field).name);
}

fn GetTable(comptime table_name: []const u8) type {
    const info = @typeInfo(@TypeOf(tables)).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (std.mem.eql(u8, name, table_name)) {
            return T;
        }
    }

    @compileError("Table '" ++ table_name ++ "' not found in tables");
}

fn getTable(comptime table_name: []const u8) GetTable(table_name) {
    return @field(tables, table_name);
}

fn data(comptime table: anytype, cp: u21) TableData(@TypeOf(table)) {
    const stage1_idx = cp >> 8;
    const stage2_idx = cp & 0xFF;
    if (@hasField(@TypeOf(table), "stage3")) {
        return table.stage3[table.stage2[table.stage1[stage1_idx] + stage2_idx]];
    } else {
        return table.stage2[table.stage1[stage1_idx] + stage2_idx];
    }
}

pub fn getAll(comptime table_name: []const u8, cp: u21) TypeOfAll(table_name) {
    const table = comptime getTable(table_name);
    return data(table, cp);
}

pub fn TypeOfAll(comptime table_name: []const u8) type {
    return TableData(GetTable(table_name));
}

pub const FieldEnum = blk: {
    var fields_len: usize = 0;
    for (structFields(@TypeOf(tables))) |tableInfo| {
        fields_len += structFields(TableData(tableInfo.type)).len;
    }

    const TagInt = std.math.IntFittingRange(0, fields_len - 1);
    var field_names: [fields_len][]const u8 = undefined;
    var field_values: [fields_len]TagInt = undefined;
    var i: usize = 0;

    for (structFields(@TypeOf(tables))) |tableInfo| {
        for (structFields(TableData(tableInfo.type))) |f| {
            field_names[i] = f.name;
            field_values[i] = i;
            i += 1;
        }
    }

    break :blk @Enum(TagInt, .exhaustive, &field_names, &field_values);
};

fn DataField(comptime field: []const u8) type {
    return @FieldType(TableData(tableInfoFor(field).type), field);
}

pub fn WithBacking(comptime S: type) type {
    const T = @typeInfo(S.Backing).pointer.child;
    return struct {
        slice: S,
        backing: S.Backing,

        pub fn with(self: *const @This(), single_item_buffer: *[1]T, cp: u21) []const T {
            return self.slice.valueWith(self.backing, single_item_buffer, cp);
        }
    };
}

fn FieldValue(comptime field: []const u8) type {
    const D = DataField(field);
    if (@typeInfo(D) == .@"struct") {
        if (@hasDecl(D, "unshift") and @TypeOf(D.unshift) != void) {
            return @typeInfo(@TypeOf(D.unshift)).@"fn".return_type.?;
        } else if (@hasDecl(D, "unpack")) {
            return @typeInfo(@TypeOf(D.unpack)).@"fn".return_type.?;
        } else if (@hasDecl(D, "value") and @TypeOf(D.value) != void) {
            return @typeInfo(@TypeOf(D.value)).@"fn".return_type.?;
        } else if (@hasDecl(D, "Backing")) {
            return WithBacking(D);
        } else {
            return D;
        }
    } else {
        return D;
    }
}

// Note: I tried using a union with members that are the known types, and using
// @FieldType(KnownFieldsForLspUnion, field) but the LSP was still unable to
// figure out the type. It seems like the only way to get the LSP to know the
// type would be having dedicated `get` functions for each field, but I don't
// want to go that route.
pub fn get(comptime field: FieldEnum, cp: u21) TypeOf(field) {
    const name = @tagName(field);
    const D = DataField(name);
    const table = comptime tableFor(name);

    if (@typeInfo(D) == .@"struct" and (@hasDecl(D, "unpack") or @hasDecl(D, "unshift") or @hasDecl(D, "Backing"))) {
        const d = @field(data(table, cp), name);
        if (@hasDecl(D, "unshift") and @TypeOf(D.unshift) != void) {
            return d.unshift(cp);
        } else if (@hasDecl(D, "unpack")) {
            return d.unpack();
        } else if (@hasDecl(D, "value") and @TypeOf(D.value) != void) {
            return d.value(backingFor(name));
        } else {
            return .{ .slice = d, .backing = backingFor(name) };
        }
    } else {
        return @field(data(table, cp), name);
    }
}

pub fn TypeOf(comptime field: FieldEnum) type {
    return FieldValue(@tagName(field));
}
