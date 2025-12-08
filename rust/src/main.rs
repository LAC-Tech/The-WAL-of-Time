#![cfg_attr(not(test), no_std)]

fn main() {
    let sm = state_machine::StateMachine::default();
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

/// This modules bridges the gap between the state machine and particular OS
/// They are OS independent, but also represent quite low level operations
mod os {
    enum Req {
        Read,
        Write,
    }

    enum Res {
        Read,
        Write,
    }

    trait OS {
        fn wait_for_res() -> Res;
        fn submit(reqs: &[Req]);
    }
}

mod state_machine {
    mod config {
        // TODO: come up with reasoning for this number, and stick with it
        pub const MAX_REPLICAS: usize = 32;
    }

    #[derive(Copy, Clone, Default, Ord, Eq, PartialEq, PartialOrd)]
    struct NodeID(u128);

    #[derive(Default)]
    pub struct StateMachine {
        local_fd: i32,
        remote_fds: remote_fds::Map,
    }

    mod remote_fds {
        use super::{NodeID, config};

        #[derive(Default)]
        pub struct Map {
            elems: [(NodeID, i32); config::MAX_REPLICAS],
            len: usize,
        }

        enum MapErr {
            Overflow,
            AlreadyExists,
        }

        // Fixed Capacity, sorted array
        impl Map {
            fn get(&self, node_id: NodeID) -> Option<i32> {
                self.elems[..self.len]
                    .binary_search_by_key(&node_id, |(id, _fd)| *id)
                    .ok()
                    .map(|index| self.elems[index].1)
            }

            fn add(&mut self, node_id: NodeID, fd: i32) -> Result<(), MapErr> {
                if self.len >= self.elems.len() {
                    return Err(MapErr::Overflow);
                }

                let existing_fd = self.elems[..self.len]
                    .binary_search_by_key(&node_id.0, |(id, _fd)| id.0);

                match existing_fd {
                    Ok(_) => Err(MapErr::AlreadyExists),
                    Err(pos) => {
                        // Shift elements to the right to make space
                        for i in (pos..self.len).rev() {
                            self.elems[i + 1] = self.elems[i];
                        }
                        self.elems[pos] = (node_id, fd);
                        self.len += 1;
                        Ok(())
                    }
                }
            }
        }
    }
}
