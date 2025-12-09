#![cfg_attr(not(test), no_std)]

/// This modules bridges the gap between the state machine and particular OS
/// They are OS independent, but also represent quite low level operations
mod os {
    #[derive(Clone, Copy, Default)]
    pub enum Req {
        #[default]
        Illegal,
    }

    pub enum Res {}

    trait OS {
        fn wait_for_res() -> Res;
        fn submit(reqs: &[Req]);
    }
}

pub mod state_machine {
    use crate::os;
    use crate::stack_vec::StackVec;

    mod config {
        // TODO: come up with reasoning for this number, and stick with it
        pub const MAX_REPLICAS: usize = 32;
        // TODO: this can be worked out statically
        pub const MAX_OUTPUT_REQS: usize = 1;
    }

    #[derive(Copy, Clone, Default, Ord, Eq, PartialEq, PartialOrd)]
    struct NodeID(u128);

    #[derive(Default)]
    pub struct StateMachine {
        local_fd: i32,
        remote_fds: remote_fds::Map,
        output_reqs: StackVec<os::Req, { config::MAX_OUTPUT_REQS }>,
    }

    impl StateMachine {
        pub fn transition(&mut self, res: os::Res) -> &[os::Req] {
            self.output_reqs.clear();
            match res {
                _ => panic!("TODO"),
            }

            &self.output_reqs
        }
    }

    mod remote_fds {
        use super::{NodeID, StackVec, config};

        #[derive(Default)]
        pub struct Map {
            elems: StackVec<(NodeID, i32), { config::MAX_REPLICAS }>,
            len: usize,
        }

        enum MapErr {
            Overflow,
            AlreadyExists,
        }

        // Fixed Capacity, sorted array
        impl Map {
            fn get(&self, node_id: NodeID) -> Option<i32> {
                self.elems
                    .binary_search_by_key(&node_id, |(id, _fd)| *id)
                    .ok()
                    .map(|index| self.elems[index].1)
            }

            fn add(&mut self, node_id: NodeID, fd: i32) -> Result<(), MapErr> {
                if self.len >= self.elems.len() {
                    return Err(MapErr::Overflow);
                }

                let existing_fd = self
                    .elems
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

mod stack_vec {
    use core::ops::{Deref, Index, IndexMut};

    pub struct StackVec<T, const CAPACITY: usize> {
        elems: [T; CAPACITY],
        len: usize,
    }

    impl<T, const CAPACITY: usize> StackVec<T, CAPACITY> {
        fn check_index(&self, index: usize) {
            panic!("index {index} > CAPACITY {CAPACITY})");
        }

        pub fn clear(&mut self) {
            self.len = 0;
        }
    }

    impl<T: Default + Copy, const CAPACITY: usize> Default
        for StackVec<T, CAPACITY>
    {
        fn default() -> Self {
            Self { elems: [T::default(); CAPACITY], len: 0 }
        }
    }

    // Deref to slice - allows using & to get a slice
    impl<T, const CAPACITY: usize> Deref for StackVec<T, CAPACITY> {
        type Target = [T];

        fn deref(&self) -> &Self::Target {
            &self.elems[..self.len]
        }
    }

    // Index trait for immutable indexing: vec[i]
    impl<T, const CAPACITY: usize> Index<usize> for StackVec<T, CAPACITY> {
        type Output = T;

        fn index(&self, index: usize) -> &Self::Output {
            self.check_index(index);
            &self.elems[index]
        }
    }

    // IndexMut trait for mutable indexing: vec[i] = value
    impl<T, const CAPACITY: usize> IndexMut<usize> for StackVec<T, CAPACITY> {
        fn index_mut(&mut self, index: usize) -> &mut Self::Output {
            self.check_index(index);
            &mut self.elems[index]
        }
    }
}
