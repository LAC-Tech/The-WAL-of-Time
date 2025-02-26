use rand::prelude::*;

use rust::DB;

mod os {
    use super::usr;
    use rand::prelude::*;
    use rust::{DB, FileIO, IOReq, IORes};
    use std::collections::BinaryHeap;

    pub type FD = usize;
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

    #[derive(Clone, Copy, Debug, Default)]
    pub struct Stats {
        files_created: u64,
    }
    pub struct OS {
        events: BinaryHeap<Event>,
        files: Vec<Vec<u8>>,
        // Needs its own rng so we can confrom to FileIO interface
        // TODO: make FileIO pass in some arbitrary "context" parameter???
        rng: SmallRng,
        pub stats: Stats,
    }

    impl OS {
        pub fn new(seed: u64) -> Self {
            Self {
                events: BinaryHeap::new(),
                files: vec![],
                rng: SmallRng::seed_from_u64(seed),
                stats: Stats::default(),
            }
        }

        // Advances the state of the OS.
        // Should not happen every sim tick, I don't think
        pub fn tick(&mut self, db: &mut DB<FD>, usr_ctx: &mut usr::Ctx) {
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

            db.receive_io(res, usr_ctx);
        }
    }

    impl FileIO for OS {
        type FD = FD;
        fn send(&mut self, req: IOReq<FD>) {
            let priority: u64 = self.rng.random();
            let e = Event { priority, req };
            self.events.push(e);
        }
    }
}

mod usr {
    use rust::{CreateStreamErr, UserCtx};

    #[derive(Default)]
    pub struct Ctx {
        pub stats: Stats,
    }

    #[derive(Clone, Copy, Debug, Default)]
    pub struct Stats {
        streams_created: u64,
        stream_name_duplicates: u64,
        stream_name_reservation_limit_exceeded: u64,
    }

    impl Ctx {
        pub fn on_stream_create_req_err(&mut self, err: CreateStreamErr) {
            match err {
                CreateStreamErr::DuplicateName => {
                    self.stats.stream_name_duplicates += 1
                }
                CreateStreamErr::ReservationLimitExceeded => {
                    self.stats.stream_name_reservation_limit_exceeded += 1
                }
            }
        }
    }

    impl UserCtx for Ctx {
        fn send<'a>(&mut self, res: rust::URes<'a>) {
            match res {
                rust::URes::StreamCreated { .. } => {
                    self.stats.streams_created += 1
                }
            }
        }
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
    usr_ctx: usr::Ctx,
    db: DB<'a, os::FD>,
    os: os::OS,
    rsng: RandStreamNameGenerator,
}

impl<'a> Simulator<'a> {
    fn new(seed: u64) -> Self {
        let mut rng = rand::rngs::SmallRng::seed_from_u64(seed);
        let user_ctx = usr::Ctx::default();
        let db = DB::new(seed);
        let os = os::OS::new(seed);
        let rsng = RandStreamNameGenerator::new(&mut rng);

        Self { rng, usr_ctx: user_ctx, os, db, rsng }
    }

    fn tick(&mut self) {
        if config::CREATE_STREAM_CHANCE > self.rng.random() {
            if let Some(s) = self.rsng.get(&mut self.rng) {
                if let Err(err) = self.db.create_stream(s, &mut self.os) {
                    self.usr_ctx.on_stream_create_req_err(err);
                }
            }
        }
        if config::ADVANCE_OS_CHANCE > self.rng.random() {
            self.os.tick(&mut self.db, &mut self.usr_ctx);
        }
    }

    fn stats(&self) -> (os::Stats, usr::Stats) {
        (self.os.stats, self.usr_ctx.stats)
    }
}

fn bg_simulation(sim: &mut Simulator) {
    for _time_in_ms in (0..=config::MAX_TIME_IN_MS).step_by(10) {
        sim.tick();
    }
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

    println!("Stats: {:?}", sim.stats());
}
