const std = @import("std");
const c = @cImport(@cInclude("curl/curl.h"));

const log = std.log.scoped(.email);

const Email = @This();

const payload_text =
    "Date: Mon, 29 Nov 2010 21:54:29 +1100\r\n" ++
    "To: {} \r\n" ++
    "From: {} \r\n" ++
    "Message-ID: <dcd7cb36-11db-487a-9f3a-e652a9458efd@rfcpedant.example.org>\r\n" ++
    "Subject: SMTP example message\r\n" ++
    "\r\n" ++
    "The body of the message starts here.\r\n" ++
    "\r\n" ++
    "It could be a lot of lines, could be MIME encoded, whatever.\r\n" ++
    "Check RFC 5322.\r\n";

pub fn payload_source(ptr: [*]u8, size: usize, nmemb: usize, userdata: *anyopaque) callconv(.C) usize {
    const bytes_read: *usize = @ptrCast(@alignCast(userdata));
    var data: []const u8 = undefined;
    const room = size * nmemb;

    if ((size == 0) or (nmemb == 0) or ((size * nmemb) < 1)) {
        return 0;
    }

    data = payload_text[bytes_read.*..];

    if (room < data.len) data = data[0..room];
    @memcpy(ptr[0..data.len], data);
    bytes_read.* += data.len;
    return data.len;
}

pub const From = struct {
    server: [:0]const u8,
    mail: [:0]const u8,
    userpwd: [:0]const u8,
};

pub fn send(from: From, to: [:0]const u8) !void {
    var res: c.CURLcode = c.CURLE_OK;
    var recipients: ?[*]c.curl_slist = null;
    var upload_ctx: usize = 0;

    const curl = c.curl_easy_init() orelse return error.InitFailed;
    // This is the URL for your mailserver */
    _ = c.curl_easy_setopt(curl, c.CURLOPT_URL, from.server.ptr);

    // Note that this option is not strictly required, omitting it results in
    // libcurl sending the MAIL FROM command with empty sender data. All
    // autoresponses should have an empty reverse-path, and should be directed
    // to the address in the reverse-path which triggered them. Otherwise,
    // they could cause an endless loop. See RFC 5321 Section 4.5.5 for more
    // details.
    //
    _ = c.curl_easy_setopt(curl, c.CURLOPT_MAIL_FROM, from.mail.ptr);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_USERPWD, from.userpwd.ptr);

    // Add two recipients, in this particular case they correspond to the
    // To: and Cc: addressees in the header, but they could be any kind of
    // recipient. */
    recipients = c.curl_slist_append(recipients, to.ptr);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_MAIL_RCPT, recipients);

    // We are using a callback function to specify the payload (the headers and
    // body of the message). You could just use the c.CURLOPT_READDATA option to
    // specify a FILE pointer to read from. */
    _ = c.curl_easy_setopt(curl, c.CURLOPT_READFUNCTION, payload_source);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_READDATA, &upload_ctx);
    _ = c.curl_easy_setopt(curl, c.CURLOPT_UPLOAD, @as(usize, 1));

    // Send the message */
    res = c.curl_easy_perform(curl);

    // Check for errors */
    if (res != c.CURLE_OK) {
        log.err("curl_easy_perform failed: {s}", .{c.curl_easy_strerror(res)});
    }

    // Free the list of recipients */
    c.curl_slist_free_all(recipients);

    // curl does not send the QUIT command until you call cleanup, so you
    // should be able to reuse this connection for additional messages
    // (setting c.CURLOPT_MAIL_FROM and c.CURLOPT_MAIL_RCPT as required, and
    // calling curl_easy_perform() again. It may not be a good idea to keep
    // the connection open for a long time though (more than a few minutes may
    // result in the server timing out the connection), and you do want to
    // clean up in the end.
    //
    c.curl_easy_cleanup(curl);
}
