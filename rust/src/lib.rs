#![no_std]
extern crate alloc;

use alloc::boxed::Box;
use alloc::string::String;
use alloc::vec::Vec;

use foldhash::fast::FixedState;
use hashbrown::HashMap;

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
