const std = @import("std");
const sdl = @import("sdl2");
const vk = @import("vulkan");
const vkw = @import("vkw.zig");

pub fn main() !void {
    const app_name = "Vulkan SDL Test";

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try sdl.init(.{
        .video = true,
        .events = true,
        .audio = true,
    });
    defer sdl.quit();

    var window = try sdl.createWindow(app_name, .{ .centered = {} }, .{ .centered = {} }, 640, 480, .{ .vis = .shown, .context = .vulkan });
    defer window.destroy();

    const renderer = try sdl.createRenderer(window, null, .{ .accelerated = true });

    const graphics_context = try vkw.GraphicsContext.init(allocator, app_name, window);
    _ = graphics_context; // autofix

    mainLoop: while (true) {
        while (sdl.pollEvent()) |ev| {
            switch (ev) {
                .quit => break :mainLoop,
                else => {},
            }

            try renderer.setColor(.{ .r = 0, .g = 255, .b = 127, .a = 255 });
            try renderer.clear();
            renderer.present();
        }
    }
}
