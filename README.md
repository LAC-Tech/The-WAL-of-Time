# WAL of Time (WOT)

> The WAL weaves as the WAL wills

WAL of Time is a distributed log (in the sense of data storage, not logging). It's designed for high physical availability. WAL of Time is a working name, and subject to change. It will henceforth be written as WOT.

## Overview and Motivation

WOT is optimised for recording and synchronising data. That's it. That's all it does. BYO read model.

I see it as something used for ultra high availability systems, that need to respond quickly and sync later. Physically distributed data capture, in industries like logistics. Or local first type scenarios.

## Non-Goals

WOT unashamedly and intentionally prioritizes availability over consistency. A rich data model, queryability etc are non-goals; though it is envisioned that a family of CRDT views or indexes could be built atop it.

## Design

One node has many topics.
Each topic is made of 1..N logs.
There must be one local log, this represents events captured on the current node.
There can be 0..N remote logs, which represents events captured on other nodes.

The whole system is a single threaded event loop, which resolve to the following IO operations for files on disk:
- Create
- Read
- Append
- Delete

All files are append-only, and can never be modified; though they can be deleted. 

## Implementation

I have elected to implement this in Zig, for the following reasons:

- ease of C interop; C is the lingua franca of computing, and low friction in creating C bindings is very important.
- liburing style io_uring bindings built directly into the standard library
- My personal preference for parameterisable modules, ala Ocaml, over traits.
