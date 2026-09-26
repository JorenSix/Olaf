//! Olaf REST API: an HTTP front end (`olaf rest serve`) and a load balancer over
//! several of them (`olaf rest serve-lb`), with the same endpoints:
//!
//!   POST /api/store?identifier=<id>[&force]           body: audio file
//!   POST /api/query[?identifier=<label>&no_identity_match&fragmented]  body: audio file
//!   GET  /api/stats
//!   GET  /api/healthz
//!
//! Every response is an envelope with one result per database (see
//! olaf_rest_envelope.zig), also when a single database answers.
//!
//! This module only depends on std: the CLI implements `Backend` for its
//! local database (cli/olaf_cli_rest_backend.zig) and passes it to `serve`;
//! `LbBackend` forwards over HTTP instead.
const std = @import("std");

pub const api = @import("olaf_rest_api.zig");
pub const params = @import("olaf_rest_params.zig");
pub const envelope = @import("olaf_rest_envelope.zig");
pub const server = @import("olaf_rest_server.zig");
pub const lb = @import("olaf_rest_lb.zig");

pub const Endpoint = api.Endpoint;
pub const Request = api.Request;
pub const Result = api.Result;
pub const Backend = api.Backend;
pub const Params = params.Params;
pub const ServeOptions = server.Options;
pub const serve = server.serve;
pub const LbBackend = lb.LbBackend;
pub const StoreStrategy = lb.StoreStrategy;

test {
    std.testing.refAllDecls(@This());
}
