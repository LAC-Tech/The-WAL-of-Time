//! Data that's in common between the state machine and OS

const std = @import("std");

const Op = enum {
    /// Recurring request that accepts incoming client connection
    accept_client_conn,
    /// A new a connection has been created
    send_conn_ack,
    /// The client is unable to connect
    send_conn_rejected,
};

const AcceptErr = error{};
const SendErr = error{};
const RecvErr = error{};

// Pretty sure it's this in every 64 bit unix-like system.
// TODO: figure out if I care about windows
const FD = i32;

const Socket = struct {
    pub const Client = enum(FD) { _ };
    pub const Server = enum(FD) { _ };

    pub fn client_eql(a: Client, b: Client) bool {
        return std.meta.eql(a, b);
    }
};

pub const local_io = struct {
    // Aka, SQE
    pub const Req = union(Op) {
        /// Recurring request that accepts incoming client connection
        accept_client_conn,
        /// A new a connection has been created
        send_conn_ack: ClientID,
        /// The client is unable to connect
        send_conn_rejected: AcceptErr,
    };

    // Aka, CQE
    pub const Res = union(Op) {
        accept_client_conn: AcceptErr!ClientID,
        send_conn_ack: SendErr!void,
        send_conn_rejected: SendErr!void,
    };
};
const ClientID = enum(FD) { _ };
const TopicID = enum(FD) { _ };
