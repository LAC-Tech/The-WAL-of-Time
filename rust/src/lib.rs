#![no_std]
extern crate alloc;

use alloc::boxed::Box;
use alloc::vec::Vec;
use foldhash::fast::FixedState;
use hashbrown::{HashMap, HashSet, hash_map, hash_set};

pub enum IOArgs<FD> {
    Create,
    Read { buf: Vec<u8>, offset: usize },
    Append { fd: FD, data: Box<[u8]> },
    Delete(FD),
}

pub enum IORetVal<FD> {
    Create(FD),
    Read(usize),
    Append(usize),
    Delete(bool),
}

//pub type IORes<FD> = (DBReq, IORetVal<FD>);

pub trait FileIO {
    type FD;
    fn send(&mut self, req: DBReq, io_args: IOArgs<Self::FD>);
}

/// Requests: user -> node #[repr(u8)]
pub enum DBReq {
    CreateStream { name_idx: u8, _padding: u32 },
}

const _: () = {
    if core::mem::size_of::<DBReq>() != 8 {
        panic!("Requests should be 8 bytes to fit into io uring payloads");
    }
};

/// Response: node -> user
pub enum DBRes<'a> {
    StreamCreated(&'a str),
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
        let removed = core::mem::replace(&mut self.names[index as usize], "");
        self.free_indices.push(index as u8); // Mark slot as free
        removed
    }
}

pub struct DB<'a, FD> {
    rsn: RequestedStreamNames<'a>,
    streams: HashMap<&'a str, FD, FixedState>,
}

pub enum CreateStreamErr {
    DuplicateName,
    ReservationLimitExceeded,
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
            let req = DBReq::CreateStream { name_idx, _padding: 0 };
            file_io.send(req, IOArgs::Create);
        })
    }

    pub fn receive_io(
        &mut self,
        db_req: DBReq,
        ret_val: IORetVal<FD>,
        receiver: &mut impl FnMut(DBRes),
    ) {
        let db_res: DBRes = match (db_req, ret_val) {
            (DBReq::CreateStream { name_idx, .. }, IORetVal::Create(fd)) => {
                let name = self.rsn.remove(name_idx);

                match self.streams.entry(name) {
                    hash_map::Entry::Occupied(_) => {
                        panic!("Duplicate stream name")
                    }
                    hash_map::Entry::Vacant(entry) => {
                        entry.insert(fd);
                        DBRes::StreamCreated(name)
                    }
                }
            }
            _ => {
                panic!("Invalid db_req, io_ret_val pair")
            }
        };

        receiver(db_res)
    }
}

pub struct Env<'a, F: FileIO, R: FnMut(DBRes)> {
    db: DB<'a, F::FD>,
    file_io: F,
    receiver: R,
}
