#![feature(unboxed_closures)]
#![feature(fn_traits)]
use std::collections::BinaryHeap;

use rand::prelude::*;

use rust::{DB, FileIO, IOReq, IORes, URes};

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
                IORes::Create(fd, user_data)
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
    fn send<'a>(&mut self, res: URes<'a>) {
        println!("DB Response {:?} received", res)
    }
}

struct RandStreamNameGenerator {
    str: &'static [u8],
    idx: usize,
}

impl RandStreamNameGenerator {
    fn new(rng: &mut impl Rng) -> Self {
        let str: Box<[u8]> = (0..config::MAX_BYTES_STREAM_NAMES_SRC)
            .map(|_| rng.random::<u8>())
            .collect();
        let str = Box::leak(str);
        Self { str, idx: 0 }
    }

    fn get(&mut self, rng: &mut impl Rng) -> Option<&'static [u8]> {
        if self.idx >= self.str.len() {
            return None;
        }
        let remaining = self.str.len() - self.idx;
        let len =
            rng.random_range(0..=remaining.min(config::MAX_STREAM_NAME_LEN));
        let end = self.idx + len;
        let res = &self.str[self.idx..end];
        self.idx = end;
        Some(res)
    }
}

// Configuration parameters for the DST
// In one place for ease of tweaking
mod config {
    pub const MAX_TIME_IN_MS: u64 = 1000 * 60 * 60 * 24; // 24 hours,
    pub const CREATE_STREAM_CHANCE: f64 = 0.01;
    pub const ADVANCE_OS_CHANCE: f64 = 0.1;
    pub const MAX_STREAM_NAME_LEN: usize = 64;
    pub const MAX_BYTES_STREAM_NAMES_SRC: usize = 1024;
}

struct Simulator<'a> {
    rng: SmallRng,
    user_ctx: UserCtx,
    db: DB<'a, FD>,
    os: QueueOS,
    rsng: RandStreamNameGenerator,
}

impl<'a> Simulator<'a> {
    fn new(seed: u64) -> Self {
        let mut rng = rand::rngs::SmallRng::seed_from_u64(seed);
        let user_ctx = UserCtx {};
        let db = DB::new(seed);
        let os = QueueOS::new(seed);
        let rsng = RandStreamNameGenerator::new(&mut rng);

        Self { rng, user_ctx, os, db, rsng }
    }

    fn tick(&mut self) {
        if config::CREATE_STREAM_CHANCE > self.rng.random() {
            if let Some(s) = self.rsng.get(&mut self.rng) {
                self.db.create_stream(s, &mut self.os).unwrap();
            }
        }
        if config::ADVANCE_OS_CHANCE > self.rng.random() {
            self.os.tick(&mut self.db, &mut self.user_ctx);
        }
    }
}

fn bg_simulation(sim: &mut Simulator) {
    for _time_in_ms in (0..=config::MAX_TIME_IN_MS).step_by(10) {
        sim.tick();
    }

    println!("{:?}", sim.os.stats);
}

fn main() {
    let seed: u64 = std::env::args()
        .nth(2)
        .map(|s| s.parse().unwrap())
        .unwrap_or_else(|| rand::random());
    println!("Deterministic Simulation Tester");
    println!("Seed = {}", seed);
    let mut sim = Simulator::new(seed);
    bg_simulation(&mut sim);
}
