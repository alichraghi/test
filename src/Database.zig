const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));

const log = std.log.scoped(.db);

const Database = @This();

db: *c.sqlite3,

pub fn init() !Database {
    var db: ?*c.sqlite3 = undefined;
    if (c.sqlite3_open("app.db", &db) != c.SQLITE_OK) {
        log.err("init failed", .{});
        return error.InitFailed;
    }

    return .{ .db = db.? };
}

pub fn setup(db: Database) !void {
    try db.exec(CREATE_TABLES);
}

pub fn exec(db: Database, sql: [:0]const u8) !void {
    var err_msg: ?[*:0]u8 = undefined;
    if (c.sqlite3_exec(db.db, sql, null, null, &err_msg) != c.SQLITE_OK) {
        log.err("exec failed: {s}", .{err_msg.?});
        c.sqlite3_free(err_msg);
        return error.ExecFailed;
    }
}

pub fn prepare(db: Database, sql: [:0]const u8) !Statement {
    var stmt: ?*c.sqlite3_stmt = undefined;
    if (c.sqlite3_prepare_v2(db.db, sql, @intCast(sql.len), &stmt, 0) != c.SQLITE_OK) {
        log.err("prepare failed: {s}", .{c.sqlite3_errmsg(db.db)});
        return error.PrepareFailed;
    }
    return .{ .db = db.db, .stmt = stmt.? };
}

pub const Statement = struct {
    db: *c.sqlite3,
    stmt: *c.sqlite3_stmt,

    pub fn bind(stmt: Statement, values: anytype) !void {
        inline for (@typeInfo(@TypeOf(values)).Struct.fields, 1..) |field_info, i| {
            const field = @field(values, field_info.name);
            const res = switch (@typeInfo(field_info.type)) {
                .ComptimeInt, .Int => c.sqlite3_bind_int(stmt.stmt, i, field),
                // NOTE: Assumes all pointers are strings
                .Pointer => c.sqlite3_bind_text(stmt.stmt, i, field.ptr, field.len, c.SQLITE_STATIC),
                else => @panic("TODO"),
            };

            if (res != c.SQLITE_OK) {
                return error.BindingFailed;
            }
        }
    }

    pub fn exec(stmt: Statement) !void {
        const res = c.sqlite3_step(stmt.stmt);
        if (res != c.SQLITE_DONE) {
            log.err("exec failed: {s}", .{c.sqlite3_errmsg(stmt.db)});
            return error.ExecFailed;
        }
    }

    pub fn row(stmt: Statement, comptime T: type) ?T {
        const res = c.sqlite3_step(stmt.stmt);
        if (res != c.SQLITE_ROW) {
            return null;
        }

        var values: T = undefined;
        inline for (@typeInfo(T).Struct.fields, 0..) |field_info, i| {
            @field(values, field_info.name) = switch (@typeInfo(field_info.type)) {
                .Int => c.sqlite3_column_int(stmt.stmt, i),
                // NOTE: Assumes all pointers are strings
                .Pointer => std.mem.span(c.sqlite3_column_text(stmt.stmt, i)),
                else => @panic("TODO"),
            };
        }

        return values;
    }

    pub fn deinit(stmt: Statement) void {
        _ = c.sqlite3_finalize(stmt.stmt);
    }
};

pub const CREATE_TABLES =
    \\CREATE TABLE IF NOT EXISTS users (
    \\	id INTEGER PRIMARY KEY,
    \\  username TEXT NOT NULL,
    \\	password TEXT NOT NULL
    \\) WITHOUT ROWID;
;

pub const INSERT_USER =
    \\INSERT INTO users(id, username, email, password) VALUES(?, ?, ?);
;

pub const SELECT_USERS =
    \\SELECT id, username, password FROM users;
;
