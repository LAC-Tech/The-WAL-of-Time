#![no_std]
#![feature(vec_push_within_capacity)]
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
    Create(usr_data::Create),
    Read { buf: Vec<u8>, offset: usize },
    Append { fd: FD, data: Box<[u8]> },
    Delete(FD),
}

/// Response: node -> user
pub enum IORes<FD> {
    Create(FD, usr_data::Create),
    Read(usize),
    Append(usize),
    Delete(bool),
}

#[derive(Debug)]
pub enum UsrRes<'a> {
    StreamCreated(&'a str),
}

// 64 bit pieces of user data to help DB figure out what an IO req was for
mod usr_data {
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
struct RequestedStreamNames<'a> {
    names: Vec<&'a str>, // TODO: just use flat array of 256 elems?
    free_indices: Vec<u8>,
}

impl<'a> RequestedStreamNames<'a> {
    fn new() -> Self {
        Self { names: Vec::with_capacity(256), free_indices: Vec::new() }
    }
    /// Index if it succeeds, None if it's a duplicate
    fn add(&mut self, name: &'a str) -> Result<u8, CreateStreamErr> {
        if self.names.contains(&name) {
            return Err(CreateStreamErr::DuplicateName)
        }

        if let Some(index) = self.free_indices.pop() {
            self.names[index as usize] = name;
            return Ok(index);
        }

        self.names
            .push_within_capacity(name)
            .map_err(|_| CreateStreamErr::ReservationLimitExceeded)?;
        Ok((self.names.len() - 1).try_into().unwrap())
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
    fn send(&mut self, res: UsrRes<'_>);
}

pub struct DB<'a, FD> {
    rsn: RequestedStreamNames<'a>,
    streams: HashMap<&'a str, FD, FixedState>,
}

impl<'a, FD> DB<'a, FD> {
    pub fn new(seed: u64) -> Self {
        Self {
            rsn: RequestedStreamNames::new(),
            streams: HashMap::with_hasher(FixedState::with_seed(seed)),
        }
    }

    pub fn create_stream(
        &mut self,
        name: &'a str,
        file_io: &mut impl FileIO<FD = FD>,
    ) -> Result<(), CreateStreamErr> {
        self.rsn.add(name).map(|name_idx| {
            let usr_data = usr_data::Create::Stream { name_idx, _padding: 0 };
            file_io.send(IOReq::Create(usr_data));
        })
    }

    pub fn receive_io(&mut self, res: IORes<FD>, usr_ctx: &mut impl UserCtx) {
        let usr_res: UsrRes = match res {
            IORes::Create(
                fd,
                usr_data::Create::Stream { name_idx, _padding },
            ) => {
                let name = self.rsn.remove(name_idx);

                match self.streams.entry(name) {
                    hash_map::Entry::Occupied(_) => {
                        panic!("Duplicate stream name: {}", name)
                    }
                    hash_map::Entry::Vacant(entry) => {
                        entry.insert(fd);
                        UsrRes::StreamCreated(name)
                    }
                }
            }
            _ => {
                panic!("TODO: handle more io requests");
            }
        };

        usr_ctx.send(usr_res);
    }
}
