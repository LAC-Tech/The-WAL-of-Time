#![no_std]
extern crate alloc;

use alloc::boxed::Box;
use alloc::string::String;
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
    fn send(&mut self, req_id: DBReq, args: IOArgs<Self::FD>);
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
enum DBRes<'a> {
    StreamCreated(&'a str),
}

/// Streams that are waiting to be created
#[derive(Default)]
struct RequestedStreamNames {
    names: Vec<String>, // TODO: just use flat array of 256 elems?
    free_indices: Vec<u8>,
}

impl RequestedStreamNames {
    /// Index if it succeeds, None if it's a duplicate
    fn add(&mut self, name: String) -> Result<u8, CreateStreamErr> {
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

    fn remove(&mut self, index: u8) -> String {
        self.free_indices.push(index);
        let removed =
            core::mem::replace(&mut self.names[index as usize], String::new());
        self.free_indices.push(index as u8); // Mark slot as free
        removed
    }
}

pub struct DB<FD, R> {
    rsn: RequestedStreamNames,
    receiver: R,
    streams: HashMap<String, FD, FixedState>,
}

pub enum CreateStreamErr {
    DuplicateName,
    ReservationLimitExceeded,
}

impl<FD, R: FnMut(DBRes)> DB<FD, R> {
    pub fn create_stream(
        &mut self,
        name: String,
        file_io: &mut impl FileIO<FD = FD>,
    ) -> Result<(), CreateStreamErr> {
        self.rsn.add(name).map(|name_idx| {
            let req = DBReq::CreateStream { name_idx, _padding: 0 };
            file_io.send(req, IOArgs::Create);
        })
    }

    pub fn receive_io(&mut self, db_req: DBReq, ret_val: IORetVal<FD>) {
        let db_res: DBRes = match (db_req, ret_val) {
            (DBReq::CreateStream { name_idx, .. }, IORetVal::Create(fd)) => {
                let name = self.rsn.remove(name_idx);

                match self.streams.entry(name) {
                    hash_map::Entry::Occupied(_) => {
                        panic!("Duplicate stream name")
                    }
                    hash_map::Entry::Vacant(entry) => {
                        entry.insert(fd);
                        let stored_name = entry.key();
                        DBRes::StreamCreated(stored_name)
                    }
                }
            }
            _ => {
                panic!("Invalid db_req, io_ret_val pair")
            }
        };
    }
}
