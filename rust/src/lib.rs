#[no_std]
extern crate alloc;

pub trait OperatingSystem<FD> {
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
