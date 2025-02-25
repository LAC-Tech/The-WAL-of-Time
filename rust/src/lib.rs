#![no_std]

#[macro_use]
extern crate alloc;

use alloc::boxed::Box;
use alloc::vec::Vec;
use core::mem;

use foldhash::fast::FixedState;
use hashbrown::HashMap;

// Only worrying about 64 bit systems for now
const _: () = assert!(mem::size_of::<usize>() == 8);

pub trait FileIO {
    type FD;
    fn send(&mut self, req: IOReq<Self::FD>);
}

/// Requests: user -> node #[repr(u8)]
pub enum IOReq<FD> {
    Create(db_ctx::Create),
    Read { buf: Vec<u8>, offset: usize },
    Append { fd: FD, data: Box<[u8]> },
    Delete(FD),
}

/// Response: node -> user
pub enum IORes<FD> {
    Create(FD, db_ctx::Create),
    Read(usize),
    Append(usize),
    Delete(bool),
}

/// User Response
#[derive(Debug)]
pub enum URes<'a> {
    StreamCreated(&'a str),
}

/// Database Context
/// Small bits of data so the DB knows what an IO req was for when it gets the
/// response back
mod db_ctx {
    use core::mem::size_of;
    #[repr(u8)]
    pub enum Create {
        Stream { name_idx: u8, _padding: u32 },
    }

    // These are intended to be used in the user_data field of io_uring (__u64),
    // or the udata field of kqueue (void*). So we make sure they can fit in
    // 8 bytes.
    const _: () = {
        assert!(size_of::<Create>() == 8);
    };
}

/// Streams that are waiting to be created
struct RequestedStreamNames<'a> {
    /// Using an array so we can give each name a small "address"
    /// Limit the size of it 256 bytes so we can use a u8 as the index
    names: Box<[&'a str; 256]>,
    /// Allows us to remove names from the middle of the names array w/o
    /// re-ordering. If this array is empty, we've exceeded the capacity of
    /// names
    next_indices: Vec<u8>,
}

impl<'a> RequestedStreamNames<'a> {
    fn new() -> Self {
        Self { names: Box::new([""; 256]), next_indices: vec![0] }
    }
    /// Index if it succeeds, None if it's a duplicate
    fn add(&mut self, name: &'a str) -> Result<u8, CreateStreamErr> {
        if self.names.contains(&name) {
            return Err(CreateStreamErr::DuplicateName)
        }

        let Some(idx) = self.next_indices.pop() else {
            return Err(CreateStreamErr::ReservationLimitExceeded);
        };

        self.names[idx as usize] = name;

        // We can add the next name after this; unless we've reached the
        // capacity of names
        idx.checked_add(1).map(|idx| self.next_indices.push(idx));

        Ok(idx)
    }

    fn remove(&mut self, index: u8) -> &'a str {
        self.next_indices.push(index);
        mem::take(&mut self.names[index as usize])
    }
}

#[derive(Debug)]
pub enum CreateStreamErr {
    DuplicateName,
    ReservationLimitExceeded,
}

pub trait UserCtx {
    fn send(&mut self, res: URes<'_>);
}

pub struct DB<'a, FD> {
    rsn: RequestedStreamNames<'a>,
    /// Determistic Hashmap for testing
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
            let usr_data = db_ctx::Create::Stream { name_idx, _padding: 0 };
            file_io.send(IOReq::Create(usr_data));
        })
    }

    pub fn receive_io(&mut self, res: IORes<FD>, usr_ctx: &mut impl UserCtx) {
        let usr_res: URes = match res {
            IORes::Create(
                fd,
                db_ctx::Create::Stream { name_idx, _padding },
            ) => {
                let name = self.rsn.remove(name_idx);
                let prev_val = self.streams.insert(name, fd);
                assert!(prev_val.is_none(), "Duplicate Stream Name :{}", name);
                URes::StreamCreated(name)
            }

            _ => {
                panic!("TODO: handle more io requests");
            }
        };

        usr_ctx.send(usr_res);
    }
}
