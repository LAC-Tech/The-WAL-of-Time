use rust::os;
use std::collections::BinaryHeap;

use rand::prelude::*;
type FD = usize;

struct OS {
    // TODO: extremely nested heap memory, this should be a single &[u8]
    fs: Vec<Vec<u8>>,
    events: BinaryHeap<Event>,
    // TODO: inefficient, involves a vtable
    receiver: Box<dyn FnMut(os::Output<FD>)>,
}

impl OS {
    fn tick(&mut self) {
        match self.events.pop() {
            None => {}
            Some(e) => match e.os_input.args {
                os::IoArgs::Create => {
                    let fd = self.fs.len();
                    self.fs.push(Vec::new());
                    (self.receiver)(os::Output {
                        task_id: e.os_input.task_id,
                        ret_val: os::IoRetVal::Create(fd),
                    })
                }
                _ => panic!("TODO: implement all os input arg handling"),
            },
        }
    }
}

impl os::OperatingSystem for OS {
    type FD = FD;
    type Env = Env;

    fn new(receiver: Box<dyn FnMut(os::Output<FD>)>) -> Self {
        Self { fs: vec![], events: BinaryHeap::new(), receiver }
    }

    fn send(&mut self, env: &mut Env, os_input: os::Input<Self::FD>) {
        let event = Event { priority: env.rng.random(), os_input };
        self.events.push(event);
    }
}

struct Env {
    rng: SmallRng,
}

#[derive(Ord, PartialOrd, Eq, PartialEq)]
struct Event {
    priority: u64,
    os_input: os::Input<FD>,
}

fn main() {
    println!("ROFL");
}
