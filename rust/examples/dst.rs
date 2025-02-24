#![feature(unboxed_closures)]
#![feature(fn_traits)]
use std::collections::BinaryHeap;

use rand::prelude::*;

use rust::{DB, DBReq, DBRes, FileIO, IOArgs, IORetVal};

type FD = usize;

struct Event {
    priority: u64,
    req: DBReq,
    io_args: IOArgs<FD>,
}

impl PartialEq for Event {
    fn eq(&self, other: &Self) -> bool { self.priority == other.priority }
}
impl Eq for Event {}
impl PartialOrd for Event {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.priority.cmp(&other.priority))
    }
}

impl Ord for Event {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.priority.cmp(&other.priority)
    }
}

struct QueueOS {
    events: BinaryHeap<Event>,
    files: Vec<Vec<u8>>,
    rng: SmallRng,
}

impl QueueOS {
    fn new(rng: SmallRng) -> Self {
        Self { events: BinaryHeap::new(), files: vec![], rng }
    }

    // Advances the state of the OS.
    // Should not happen every sim tick, I don't think
    fn tick(&mut self, db: &mut DB<FD>, user_ctx: &mut UserCtx) {
        match self.events.pop() {
            None => return,
            Some(e) => match e.io_args {
                IOArgs::Create => {
                    self.files.push(vec![]);
                    let fd = self.files.len() - 1;
                    db.receive_io(e.req, IORetVal::Read(fd), user_ctx);
                }
                _ => panic!("TODO: handle more events"),
            },
        }
    }
}

impl FileIO for QueueOS {
    type FD = FD;
    fn send(&mut self, req: DBReq, io_args: rust::IOArgs<Self::FD>) {
        let priority: u64 = self.rng.random();
        let e = Event { priority, req, io_args };
        self.events.push(e);
    }
}

struct UserCtx {}
impl FnMut(DBRes<'_>) for UserCtx {
    extern "rust-call" fn call_mut(&mut self, args: DBRes) -> Self::Output {
        println!("user ctx received a result!!11!");
    _
}

// Configuration parameters for the DST
// In one place for ease of tweaking
mod config {
    /*
    const MAX_TIME_IN_MS: u64 = 1000 * 60 * 60 * 24; // 24 hours,
    const CREATE_STREAM_CHANCE: f64 = 0.1;
    */

    const MAX_IO_DELAY_STEPS: u32 = 5;

    pub fn delay_steps(rng: &mut impl rand::Rng) -> u32 {
        rng.random::<u32>() % MAX_IO_DELAY_STEPS
    }
}

fn main() {
    println!("Deterministic simulation tester");
    let rng = rand::rngs::SmallRng::seed_from_u64(0);
}
