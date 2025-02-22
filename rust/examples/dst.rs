use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};

use rand::SeedableRng;
use rust::FileIO;

// Configuration parameters for the DST
// In one place for ease of tweaking
mod config {
    /*
    const MAX_TIME_IN_MS: u64 = 1000 * 60 * 60 * 24; // 24 hours,
    const CREATE_STREAM_CHANCE: f64 = 0.1;
    */

    const MAX_IO_DELAY_STEPS: u32 = 5;

    pub fn delay_steps(rng: &mut impl rand::Rng) -> u32 {
        rng.random::<u32>() % MAX_IO_DELAY_STEPS
    }
}

mod future {
    use super::FS;
    use std::pin::Pin;
    use std::task::{Context, Poll};

    pub struct Create<'a> {
        pub delay_steps: u32,
        pub fs: &'a mut FS,
    }

    pub struct Read<'a> {
        pub delay_steps: u32,
        pub fs: &'a mut FS,
        pub buf: &'a mut Vec<u8>,
        pub offset: usize,
    }

    pub struct Append<'a> {
        pub delay_steps: u32,
        pub fs: &'a mut FS,
        pub fd: usize,
        pub data: Option<Box<[u8]>>,
    }

    pub struct Delete<'a> {
        pub delay_steps: u32,
        pub fs: &'a mut FS,
        pub fd: usize,
    }

    fn waiting(delay_steps: &mut u32, cx: &mut Context<'_>) -> bool {
        if *delay_steps > 0 {
            *delay_steps -= 1;
            cx.waker().wake_by_ref();
            true
        } else {
            false
        }
    }

    impl<'a> Future for Create<'a> {
        type Output = usize;

        fn poll(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<Self::Output> {
            if waiting(&mut self.delay_steps, cx) {
                return Poll::Pending
            }

            self.fs.files.push(Some(Vec::new()));
            Poll::Ready(self.fs.files.len() - 1)
        }
    }

    impl<'a> Future for Read<'a> {
        type Output = usize;

        fn poll(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<Self::Output> {
            if waiting(&mut self.delay_steps, cx) {
                return Poll::Pending
            }

            let file_data = self
                .fs
                .files
                .get(self.offset)
                .and_then(|opt| opt.as_ref())
                .cloned()
                .unwrap_or_default();
            self.buf.clear();
            self.buf.extend_from_slice(&file_data);
            Poll::Ready(self.buf.len())
        }
    }

    impl<'a> Future for Append<'a> {
        type Output = usize;

        fn poll(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<Self::Output> {
            if waiting(&mut self.delay_steps, cx) {
                return Poll::Pending
            }

            let fd = self.fd;
            let data = match self.data.take() {
                Some(data) => data,
                None => return Poll::Ready(0),
            };

            if fd >= self.fs.files.len() {
                return Poll::Ready(0);
            }

            let file =
                match self.fs.files.get_mut(fd).and_then(|opt| opt.as_mut()) {
                    Some(file) => file,
                    None => return Poll::Ready(0),
                };

            file.extend_from_slice(&data);
            Poll::Ready(data.len())
        }
    }

    impl<'a> Future for Delete<'a> {
        type Output = bool;

        fn poll(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<Self::Output> {
            if waiting(&mut self.delay_steps, cx) {
                return Poll::Pending
            }

            let fd = self.fd; // avoids borrow
            let success = self.fs.files.get_mut(fd).map_or(false, |file_opt| {
                *file_opt = None;
                true
            });
            Poll::Ready(success)
        }
    }
}

// An append only file system, support Create, Append, Update, Delete
struct FS {
    files: Vec<Option<Vec<u8>>>,
    rng: rand::rngs::SmallRng,
}

impl FS {
    fn new(seed: u64) -> Self {
        Self { files: vec![], rng: rand::rngs::SmallRng::seed_from_u64(seed) }
    }
}

impl FileIO<usize> for FS {
    fn create(&mut self) -> impl Future<Output = usize> + '_ {
        let delay_steps = config::delay_steps(&mut self.rng);
        future::Create { delay_steps, fs: self }
    }

    fn read<'a>(
        &'a mut self,
        buf: &'a mut Vec<u8>,
        offset: usize,
    ) -> impl Future<Output = usize> + 'a {
        let delay_steps = config::delay_steps(&mut self.rng);
        future::Read { delay_steps, fs: self, buf, offset }
    }

    fn append(
        &mut self,
        fd: usize,
        data: Box<[u8]>,
    ) -> impl Future<Output = usize> + '_ {
        let delay_steps = config::delay_steps(&mut self.rng);
        future::Append { delay_steps, fs: self, fd, data: Some(data) }
    }

    fn delete(&mut self, fd: usize) -> impl Future<Output = bool> + '_ {
        let delay_steps = config::delay_steps(&mut self.rng);
        future::Delete { delay_steps, fs: self, fd }
    }
}

// Random priority to increase "chaos" in simulation
struct Task {
    priority: u32,
    future: Pin<Box<dyn Future<Output = ()> + 'static>>,
}

impl PartialEq for Task {
    fn eq(&self, other: &Self) -> bool { self.priority == other.priority }
}

impl Eq for Task {}

impl PartialOrd for Task {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Task {
    fn cmp(&self, other: &Self) -> Ordering {
        self.priority.cmp(&other.priority)
    }
}

// Single threaded, deterministic async runtime
struct Runtime {
    tasks: BinaryHeap<Task>,
    waker: Option<Waker>,
}

impl Runtime {
    fn new() -> Self { Runtime { tasks: BinaryHeap::new(), waker: None } }

    fn create_waker(&mut self) -> Waker {
        fn clone(data: *const ()) -> RawWaker { RawWaker::new(data, &VTABLE) }
        fn wake(_data: *const ()) {} // No-op, queue handles re-polling
        fn wake_by_ref(_data: *const ()) {}
        fn drop(_data: *const ()) {}

        static VTABLE: RawWakerVTable =
            RawWakerVTable::new(clone, wake, wake_by_ref, drop);

        self.waker
            .get_or_insert_with(|| unsafe {
                Waker::from_raw(RawWaker::new(
                    std::ptr::null::<()>() as *const _,
                    &VTABLE,
                ))
            })
            .clone()
    }

    fn spawn(
        &mut self,
        rng: &mut impl rand::Rng,
        future: impl Future<Output = ()> + 'static,
    ) {
        let t =
            Task { priority: rng.random::<u32>(), future: Box::pin(future) };
        self.tasks.push(t);
    }

    fn run(&mut self) {
        while !self.tasks.is_empty() {
            // Poll one task per iteration to avoid overlapping borrows
            if let Some(mut task) = self.tasks.pop() {
                let waker = self.create_waker();
                let mut context = Context::from_waker(&waker);
                match task.future.as_mut().poll(&mut context) {
                    Poll::Pending => self.tasks.push(task),
                    Poll::Ready(()) => {}
                }
            }
        }
    }
}

async fn run_fs(mut fs: FS) {
    let fd = fs.create().await;
    println!("Created file with FD: {}", fd);

    let data = vec![42, 43, 44].into_boxed_slice();
    let bytes_written = fs.append(fd, data).await;
    println!("Appended {} bytes", bytes_written);

    let mut buf = Vec::new();
    let bytes_read = fs.read(&mut buf, fd).await;
    println!("Read {} bytes: {:?}", bytes_read, buf);

    let success = fs.delete(fd).await;
    println!("Deleted FD {}: {}", fd, success);
}

fn main() {
    let mut runtime = Runtime::new();
    let mut rng = rand::rngs::SmallRng::seed_from_u64(42);
    runtime.spawn(&mut rng, run_fs(FS::new(42)));
    runtime.run();
}
