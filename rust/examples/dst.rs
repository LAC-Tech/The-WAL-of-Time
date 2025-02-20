use rust::os;
use std::collections::BinaryHeap;

use rand::prelude::*;
type FD = usize;

struct OS<Receiver: FnMut(os::Output<FD>)> {
    // TODO: extremely nested heap memory, this should be a single &[u8]
    fs: Vec<Vec<u8>>,
    events: BinaryHeap<Event>,
    receiver: Reciever,
}

impl<Receiver: FnMut(os::Output<FD>)> OS<Receiver> {
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

    fn new(on_receive: impl FnMut(os::Output<FD>)) -> Self {
        Self { fs: vec![], events: BinaryHeap::new(), receiver: on_receive }
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
