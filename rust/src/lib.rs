#![no_std]
extern crate alloc;

use alloc::boxed::Box;
use alloc::string::String;
use alloc::vec::Vec;

mod file_io {
    use super::db;
    use alloc::boxed::Box;
    use alloc::vec::Vec;

    pub enum Args<FD> {
        Create,
        Read { buf: Vec<u8>, offset: usize },
        Append { fd: FD, data: Box<[u8]> },
        Delete(FD),
    }

    enum RetVal<FD> {
        Create(FD),
        Read(usize),
        Append(usize),
        Delete(bool),
    }

    type Req<FD> = (db::ReqID, Args<FD>);
    pub type Res<FD> = (db::ReqID, RetVal<FD>);

    pub trait FileIO {
        type FD;
        fn send(&mut self, req_id: db::ReqID, args: Args<Self::FD>);
    }
}

mod db {
    use super::file_io;
    use alloc::string::String;
    use alloc::vec::Vec;
    use foldhash::fast::FixedState;
    use hashbrown::{HashMap, HashSet, hash_map, hash_set};

    pub type ReqID = u64;

    #[derive(Clone)]
    enum Req<'a> {
        CreateStream(&'a str),
    }

    enum Res {
        StreamCreated(String),
    }

    // State associated with requests that are in flight
    #[derive(Default)]
    struct Inflight<'a> {
        req_stream_names: HashSet<String, FixedState>,
        reqs: Vec<Req>,
        free_indices: Vec<usize>,
    }

    impl Inflight {
        fn add(&mut self, req: Req) -> ReqID {
            if let Some(index) = self.free_indices.pop() {
                self.reqs[index] = req;
                index as ReqID
            } else {
                self.reqs.push(req);
                (self.reqs.len() - 1) as ReqID
            }
        }

        fn remove(&mut self, req_id: ReqID) -> Req {
            let index = req_id as usize;
            self.free_indices.push(index);
            self.reqs[index].clone()
        }

        fn create_stream(&mut self, name: String) -> Result<ReqID, &str> {
            match self.req_stream_names.entry(name) {
                hash_set::Entry::Vacant(entry) => {
                    entry.insert();
                }
                hash_set::Entry::Occupied(_) => {
                    return Err("Stream name already exists")
                }
            }

            let req_id = self.reqs.add(Req::CreateStream(&name));
            Ok(req_id)
        }
    }

    struct DB<FD, R> {
        inflight: Inflight,
        receiver: R,
        streams: HashMap<String, Option<FD>, FixedState>,
    }

    impl<FD, R: FnMut(Req)> DB<FD, R> {
        fn create_stream(
            &mut self,
            name: String,
            file_io: &mut impl file_io::FileIO<FD = FD>,
        ) -> Result<(), &str> {
            self.inflight.create_stream(name).map(|req_id| {
                file_io.send(req_id, file_io::Args::Create);
            })
        }

        fn receive_io(&mut self, (req_id, ret_val): file_io::Res<FD>) {
            let req = self.inflight.remove(req_id);

            match req {
                Req::CreateStream(name) => self.streams.insert(name, ret_val),
            }
        }

        /*
        pub fn receive_io(
            self: *@This(),
            file_op: FileOp(FD).Output,
        ) !void {
            const req = try self.reqs.remove(file_op.req_id);

            switch (req) {
                .create_stream => |name| {
                    self.streams.insert(name, file_op.ret_val);
                    onReceive(self.ctx, .{.stream_created + name});
                },
            }
        }
        */
    }
}

/*
pub trait FileIO<FD> {
    fn create(&mut self) -> impl Future<Output = FD> + '_;
    fn read<'a>(
        &'a mut self,
        buf: &'a mut Vec<u8>,
        offset: usize,
    ) -> impl Future<Output = usize> + 'a;
    fn append(
        &mut self,
        fd: FD,
        data: Box<[u8]>,
    ) -> impl Future<Output = usize> + '_;
    fn delete(&mut self, fd: FD) -> impl Future<Output = bool> + '_;
}

pub struct DB<FD, FIO: FileIO<FD>> {
    file_io: FIO,
    streams: HashMap<String, FD, FixedState>,
}

impl<FD, FIO: FileIO<FD>> DB<FD, FIO> {
    pub fn new(file_io: FIO, seed: u64) -> Self {
        let streams = HashMap::with_hasher(FixedState::with_seed(seed));
        Self { file_io, streams }
    }

    pub async fn create_stream(&mut self, name: &str) -> Result<(), &str> {
        let fd = self.file_io.create().await;
        match self.streams.entry(String::from(name)) {
            hashbrown::hash_map::Entry::Vacant(entry) => {
                entry.insert(fd);
                Ok(())
            }
            hashbrown::hash_map::Entry::Occupied(_) => {
                Err("Stream name already exists")
            }
        }
    }
}
*/
