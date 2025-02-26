#![no_std]

#[macro_use]
extern crate alloc;

use alloc::boxed::Box;
use alloc::string::String;
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
    StreamCreated { name: &'a [u8] },
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
    names: Box<[&'a [u8]; 64]>,
    /// Bitmask where 1 = occupied, 0 = available
    /// Allows us to remove names from the middle of the names array w/o
    /// re-ordering. If this array is empty, we've exceeded the capacity of
    /// names
    used_slots: u64,
}

impl<'a> RequestedStreamNames<'a> {
    fn new() -> Self { Self { names: Box::new([b""; 64]), used_slots: 0 } }

    /// Index if it succeeds, None if it's a duplicate
    fn add(&mut self, name: &'a [u8]) -> Result<u8, CreateStreamErr> {
        if self.names.contains(&name) {
            return Err(CreateStreamErr::DuplicateName)
        }

        // Find first free slot
        let idx = (!self.used_slots).trailing_zeros() as u8;
        if idx >= 64 {
            return Err(CreateStreamErr::ReservationLimitExceeded);
        }

        // Mark slot as used
        self.used_slots |= 1u64 << idx;
        self.names[idx as usize] = name;

        Ok(idx)
    }

    fn remove(&mut self, index: u8) -> &'a [u8] {
        assert!(index < 64, "Index out of bounds");
        self.used_slots &= !(1u64 << index);
        core::mem::take(&mut self.names[index as usize])
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
    streams: HashMap<&'a [u8], FD, FixedState>,
}

impl<'a, FD> DB<'a, FD> {
    pub fn new(seed: u64) -> Self {
        Self {
            rsn: RequestedStreamNames::new(),
            streams: HashMap::with_hasher(FixedState::with_seed(seed)),
        }
    }
    /// The stream name is raw bytes; focusing on linux first, and ext4
    /// filenames are bytes, not a particular encoding.
    /// TODO: some way of translating this into the the platforms native
    /// filename format ie utf-8 for OS X, utf-16 for windows
    pub fn create_stream(
        &mut self,
        name: &'a [u8],
        file_io: &mut impl FileIO<FD = FD>,
    ) -> Result<(), CreateStreamErr> {
        let name_idx = self.rsn.add(name)?;
        let usr_data = db_ctx::Create::Stream { name_idx, _padding: 0 };
        file_io.send(IOReq::Create(usr_data));
        Ok(())
    }

    pub fn receive_io(&mut self, res: IORes<FD>, usr_ctx: &mut impl UserCtx) {
        let usr_res = match res {
            IORes::Create(
                fd,
                db_ctx::Create::Stream { name_idx, _padding },
            ) => {
                let name = self.rsn.remove(name_idx);
                let prev_val = self.streams.insert(name, fd);
                assert!(
                    prev_val.is_none(),
                    "Duplicate Stream Name :{}",
                    String::from_utf8_lossy(name)
                );
                URes::StreamCreated { name }
            }

            _ => {
                panic!("TODO: handle more io requests");
            }
        };

        usr_ctx.send(usr_res);
    }
}
