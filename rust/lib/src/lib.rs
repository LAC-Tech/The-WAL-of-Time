#![cfg_attr(not(test), no_std)]

pub mod config;
pub mod io;

pub struct StateMachine {
    server_fd: i32,
    req_buf: [io::Req; 2],
}

impl StateMachine {
    pub fn new(server_fd: i32) -> Self {
        Self { server_fd, req_buf: [io::Req::Illegal; 2] }
    }

    pub fn transition(&mut self, res: io::Res) -> &[io::Req] {
        use io::{Req, Res, UserData};
        let Res { result, user_data, more, buf_id } = res;

        let reqs: &[Req] = match (user_data, more) {
            // Error; resubmit
            (UserData::Accept, _) if 0 > result => {
                &[Req::Accept { server_fd: self.server_fd }]
            }
            (UserData::Accept, true) => &[Req::Recv { client_fd: result }],
            (UserData::Accept, false) => &[
                Req::Recv { client_fd: result },
                Req::Accept { server_fd: self.server_fd },
            ],
            // EOF OR error; close file and release buffer
            (UserData::Recv { client_fd }, _) if 0 >= result => {
                &[Req::ReleaseBuf { buf_id }, Req::Close { client_fd }]
            }
            (UserData::Recv { client_fd }, true) => &[Req::Send {
                client_fd,
                buf_id,
                len: result.try_into().unwrap(),
            }],
            (UserData::Recv { client_fd }, false) => &[
                Req::Send {
                    client_fd,
                    buf_id,
                    len: result.try_into().unwrap(),
                },
                Req::Recv { client_fd },
            ],
            (UserData::Send { buf_id }, _) => &[Req::ReleaseBuf { buf_id }],
            (UserData::Close, _) => &[],
        };

        self.req_buf.copy_from_slice(reqs);
        &self.req_buf[0..reqs.len()]
    }
}

pub fn execute<AIO: io::AsyncIO, BR: io::BufRing>(
    async_io: &mut AIO,
    buf_ring: &mut BR,
    reqs: &[io::Req],
) -> Result<usize, AIO::Err> {
    use io::{Req, UserData};
    for &req in reqs {
        match req {
            Req::Illegal => panic!("illegal instruction!"),
            Req::Recv { client_fd } => {
                async_io.recv(UserData::Recv { client_fd })?;
            }
            Req::Send { client_fd, buf_id, len } => {
                let ud = UserData::Send { buf_id };
                let data = &buf_ring.get(buf_id)[0..len];
                async_io.send(client_fd, data, ud)?;
            }
            Req::Close { client_fd } => {
                async_io.close(client_fd, UserData::Close)?;
            }
            Req::Accept { server_fd } => {
                async_io.accept(server_fd, UserData::Accept)?;
            }
            Req::ReleaseBuf { buf_id } => {
                buf_ring.release(buf_id);
            }
        }
    }

    async_io.submit()
}

/*
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
*/
