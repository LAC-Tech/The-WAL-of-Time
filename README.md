# The WAL of Time

> The WAL weaves as the WAL wills

WAL of Time is an experimental, asynchronous event store designed for multi-master replication.

WAL of Time is a working name, and subject to change. It will henceforth be written as WOT.

## Motivation

WOT is optimised for recording and synchronising data.

## Industrial Motivation



## Non-Goals

WOT unashamedly and intentionally prioritizes availability over consistency.

A rich data model, queryabilitty etc are non-goals; though it is envisioned that a family of CRDT views or indexes could be built atop it.

## Design

WOT is built around an abstract, asynchronous file system with 4 operations; Create, Read, Append, and Delete. All files are append-only, and can never be modified; though they can be deleted.

A WOT DB is made up of multiple append-only files, called event logs. A DB must have at least one event log - that corresponding to the node the DB is on. This is the *local log*. It may in turn have zero to many *remote logs*; these are copies of events recorded on other nodes.



## Implementation

I have elected to implement this in Zig, for the following reasons:

- ease of inter-operability with C; C is the lingua franca of computing, and low friction in creating C bindings is very important.
- liburing style io_uring bindings built directly into the standard library
- My personal preference for parameterisable modules, ala Ocaml, over traits.
