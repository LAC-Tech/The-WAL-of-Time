#![feature(unboxed_closures)]
#![feature(fn_traits)]
use std::collections::BinaryHeap;

use rand::prelude::*;

use rust::{DB, FileIO, IOReq, IORes, UserRes};

type FD = usize;

struct Event {
    priority: u64,
    req: IOReq<FD>,
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

#[derive(Debug, Default)]
struct OSStats {
    files_created: u64,
}

struct QueueOS {
    events: BinaryHeap<Event>,
    files: Vec<Vec<u8>>,
    rng: SmallRng,
    stats: OSStats,
}

impl QueueOS {
    fn new(seed: u64) -> Self {
        Self {
            events: BinaryHeap::new(),
            files: vec![],
            rng: SmallRng::seed_from_u64(seed),
            stats: OSStats::default(),
        }
    }

    // Advances the state of the OS.
    // Should not happen every sim tick, I don't think
    fn tick(&mut self, db: &mut DB<FD>, user_ctx: &mut UserCtx) {
        let Some(e) = self.events.pop() else { return };
        let res = match e.req {
            IOReq::Create(user_data) => {
                self.files.push(vec![]);
                let fd = self.files.len() - 1;
                self.stats.files_created += 1;
                IORes::Create { fd, user_data }
            }
            _ => panic!("TODO: handle more events"),
        };

        db.receive_io(res, user_ctx);
    }
}

impl FileIO for QueueOS {
    type FD = FD;
    fn send(&mut self, req: IOReq<FD>) {
        let priority: u64 = self.rng.random();
        let e = Event { priority, req };
        self.events.push(e);
    }
}

struct UserCtx {}

impl rust::UserCtx for UserCtx {
    fn send<'a>(&mut self, res: UserRes<'a>) {
        println!("DB Response {:?} received", res)
    }
}

// Configuration parameters for the DST
// In one place for ease of tweaking
mod config {
    pub const MAX_TIME_IN_MS: u64 = 1000 * 60 * 60 * 24; // 24 hours,
    pub const CREATE_STREAM_CHANCE: f64 = 0.01;
    pub const ADVANCE_OS_CHANCE: f64 = 0.1;
}

struct Simulator<'a> {
    rng: SmallRng,
    user_ctx: UserCtx,
    db: DB<'a, FD>,
    os: QueueOS,
}

impl<'a> Simulator<'a> {
    fn new(seed: u64) -> Self {
        let rng = rand::rngs::SmallRng::seed_from_u64(seed);
        let user_ctx = UserCtx {};
        let db = DB::new(seed);
        let os = QueueOS::new(seed);

        Self { rng, user_ctx, os, db }
    }

    fn tick(&mut self) {
        if config::CREATE_STREAM_CHANCE > self.rng.random() {
            self.db.create_stream(self.rng.random(), &mut self.os).unwrap();
        }
        if config::ADVANCE_OS_CHANCE > self.rng.random() {
            self.os.tick(&mut self.db, &mut self.user_ctx);
        }
    }
}

fn bg_simulation(sim: &mut Simulator) {
    for time in (0..=config::MAX_TIME_IN_MS).step_by(10) {
        sim.tick();
    }

    println!("{:?}", sim.os.stats);
}

fn main() {
    println!("Deterministic simulation tester");
    let mut sim = Simulator::new(0);
    bg_simulation(&mut sim);
}
