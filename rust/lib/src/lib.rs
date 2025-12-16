#![cfg_attr(not(test), no_std)]

extern crate alloc;

#[derive(Copy, Clone, Default, Ord, Eq, PartialEq, PartialOrd)]
struct NodeID(u128);

/// Data that comes in from outside the system
mod msg {
    use crate::NodeID;

    #[derive(Clone, Copy)]
    pub enum Msg<'a> {
        LocalAppend(&'a [u8]),
        RemoteAppend(NodeID, &'a [u8]),
    }
}

/// This modules bridges the gap between the state machine and particular OS
/// They are OS independent, but also represent quite low level operations
mod os {
    use crate::msg;

    #[derive(Clone, Copy, Default)]
    pub enum Req<'a> {
        #[default]
        Illegal, // This is only here because RemoteFDs needs a default
        Recv(msg::Msg<'a>),
    }

    pub enum Res {
        Recv { rc: i32, buf_idx: u32 },
    }

    trait OS {
        fn wait_for_res() -> Res;
        fn submit(reqs: &[Req]);
    }
}

pub mod state_machine {
    use crate::{NodeID, os};
    use crate::{array_map::ArrayMap, stack_vec::StackVec};
    use alloc::boxed::Box;

    mod config {
        // TODO: come up with reasoning for this number, and stick with it
        pub const MAX_REPLICAS: usize = 32;
        // TODO: this can be worked out statically
        pub const MAX_OUTPUT_REQS: usize = 1;
        // TODO: I just made this up
        pub const MAX_RECV_SIZE_BYTES: usize = 4096;
    }

    pub struct StateMachine<'a> {
        local_fd: i32,
        remote_fds: ArrayMap<NodeID, i32, { config::MAX_REPLICAS }>,
        output_reqs: StackVec<os::Req<'a>, { config::MAX_OUTPUT_REQS }>,
        buf: Box<[u8; config::MAX_RECV_SIZE_BYTES]>,
        buf_locked: bool,
    }

    impl<'a> StateMachine<'a> {
        pub fn default() -> Self {
            Self {
                local_fd: -1,
                remote_fds: ArrayMap::default(),
                output_reqs: StackVec::default(),
                buf: Box::new([0u8; config::MAX_RECV_SIZE_BYTES]),
                buf_locked: false,
            }
        }
        pub fn transition(&mut self, res: os::Res) -> &[os::Req] {
            use os::{Req, Res};
            self.output_reqs.clear();
            match res {
                Res::Recv { rc, buf_idx }
            }

            &self.output_reqs
        }
    }
}

// Fixed Capacity, sorted array
mod array_map {
    use crate::stack_vec::StackVec;

    enum Err {
        Overflow,
        AlreadyExists,
    }

    #[derive(Default)]
    pub struct ArrayMap<K: Copy, V: Copy, const CAPACITY: usize> {
        elems: StackVec<(K, V), { CAPACITY }>,
        len: usize,
    }

    impl<K: Copy + Ord, V: Copy, const CAPACITY: usize> ArrayMap<K, V, CAPACITY> {
        fn get(&self, key: K) -> Option<V> {
            self.elems
                .binary_search_by_key(&key, |(id, _fd)| *id)
                .ok()
                .map(|index| self.elems[index].1)
        }

        fn add(&mut self, key: K, v: V) -> Result<(), Err> {
            if self.len >= self.elems.len() {
                return Err(Err::Overflow);
            }

            let existing_fd =
                self.elems.binary_search_by_key(&key, |(k, _v)| *k);

            match existing_fd {
                Ok(_) => Err(Err::AlreadyExists),
                Err(pos) => {
                    // Shift elements to the right to make space
                    for i in (pos..self.len).rev() {
                        self.elems[i + 1] = self.elems[i];
                    }
                    self.elems[pos] = (key, v);
                    self.len += 1;
                    Ok(())
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

    impl<T, const CAPACITY: usize> IndexMut<usize> for StackVec<T, CAPACITY> {
        fn index_mut(&mut self, index: usize) -> &mut Self::Output {
            self.check_index(index);
            &mut self.elems[index]
        }
    }
}
