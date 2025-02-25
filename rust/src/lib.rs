#![no_std]
extern crate alloc;

use alloc::boxed::Box;
use alloc::vec::Vec;
use core::mem;

use foldhash::fast::FixedState;
use hashbrown::{HashMap, hash_map};

pub trait FileIO {
    type FD;
    fn send(&mut self, req: IOReq<Self::FD>);
}

/// Requests: user -> node #[repr(u8)]
pub enum IOReq<FD> {
    Create(user_data::Create),
    Read { buf: Vec<u8>, offset: usize },
    Append { fd: FD, data: Box<[u8]> },
    Delete(FD),
}

/// Response: node -> user
pub enum IORes<FD> {
    Create { fd: FD, user_data: user_data::Create },
    Read(usize),
    Append(usize),
    Delete(bool),
}

#[derive(Debug)]
pub enum UserRes<'a> {
    StreamCreated(&'a str),
}

// 64 bit pieces of user data to help DB figure out what an IO req was for
mod user_data {
    use core::mem::size_of;
    #[repr(u8)]
    pub enum Create {
        Stream { name_idx: u8, _padding: u32 },
    }

    const _: () = {
        assert!(size_of::<Create>() == 8);
    };
}

/// Streams that are waiting to be created
#[derive(Default)]
struct RequestedStreamNames<'a> {
    names: Vec<&'a str>, // TODO: just use flat array of 256 elems?
    free_indices: Vec<u8>,
}

impl<'a> RequestedStreamNames<'a> {
    /// Index if it succeeds, None if it's a duplicate
    fn add(&mut self, name: &'a str) -> Result<u8, CreateStreamErr> {
        if self.names.contains(&name) {
            return Err(CreateStreamErr::DuplicateName)
        }
        let index = if let Some(index) = self.free_indices.pop() {
            self.names[index as usize] = name;
            index
        } else {
            if self.names.len() >= 256 {
                return Err(CreateStreamErr::ReservationLimitExceeded)
            }
            self.names.push(name);
            (self.names.len() - 1).try_into().unwrap()
        };

        Ok(index)
    }

    fn remove(&mut self, index: u8) -> &'a str {
        self.free_indices.push(index);
        let removed = mem::take(&mut self.names[index as usize]);
        self.free_indices.push(index); // Mark slot as free
        removed
    }
}

#[derive(Debug)]
pub enum CreateStreamErr {
    DuplicateName,
    ReservationLimitExceeded,
}

pub trait UserCtx {
    fn send(&mut self, res: UserRes<'_>);
}

pub struct DB<'a, FD> {
    rsn: RequestedStreamNames<'a>,
    streams: HashMap<&'a str, FD, FixedState>,
}

impl<'a, FD> DB<'a, FD> {
    pub fn new(seed: u64) -> Self {
        Self {
            rsn: RequestedStreamNames::default(),
            streams: HashMap::with_hasher(FixedState::with_seed(seed)),
        }
    }

    pub fn create_stream(
        &mut self,
        name: &'a str,
        file_io: &mut impl FileIO<FD = FD>,
    ) -> Result<(), CreateStreamErr> {
        self.rsn.add(name).map(|name_idx| {
            let user_data = user_data::Create::Stream { name_idx, _padding: 0 };
            file_io.send(IOReq::Create(user_data));
        })
    }

    pub fn receive_io(&mut self, res: IORes<FD>, user_ctx: &mut impl UserCtx) {
        let user_res: UserRes = match res {
            IORes::Create { fd, user_data } => match user_data {
                user_data::Create::Stream { name_idx, _padding } => {
                    let name = self.rsn.remove(name_idx);

                    match self.streams.entry(name) {
                        hash_map::Entry::Occupied(_) => {
                            panic!("Duplicate stream name: {}", name)
                        }
                        hash_map::Entry::Vacant(entry) => {
                            entry.insert(fd);
                            UserRes::StreamCreated(name)
                        }
                    }
                }
            },
            _ => {
                panic!("TODO: handle more io requests");
            }
        };

        user_ctx.send(user_res);
    }
}
