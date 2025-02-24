use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};

use rand::SeedableRng;
use rand::seq::SliceRandom;

use rust::FileIO; // Matches crate name "rust"

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
    use super::Simulator;
    use std::pin::Pin;
    use std::task::{Context, Poll};

    pub struct Create<'a> {
        pub delay_steps: u32,
        pub sim: &'a mut Simulator,
    }

    pub struct Read<'a> {
        pub delay_steps: u32,
        pub sim: &'a mut Simulator,
        pub buf: &'a mut Vec<u8>,
        pub offset: usize,
    }

    pub struct Append<'a> {
        pub delay_steps: u32,
        pub sim: &'a mut Simulator,
        pub fd: usize,
        pub data: Option<Box<[u8]>>,
    }

    pub struct Delete<'a> {
        pub delay_steps: u32,
        pub sim: &'a mut Simulator,
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
                return Poll::Pending;
            }
            self.sim.files.push(Some(Vec::new()));
            Poll::Ready(self.sim.files.len() - 1)
        }
    }

    impl<'a> Future for Read<'a> {
        type Output = usize;

        fn poll(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
        ) -> Poll<Self::Output> {
            if waiting(&mut self.delay_steps, cx) {
                return Poll::Pending;
            }
            let file_data = self
                .sim
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
                return Poll::Pending;
            }
            let fd = self.fd;
            let data = match self.data.take() {
                Some(data) => data,
                None => return Poll::Ready(0),
            };
            if fd >= self.sim.files.len() {
                return Poll::Ready(0);
            }
            let file =
                match self.sim.files.get_mut(fd).and_then(|opt| opt.as_mut()) {
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
                return Poll::Pending;
            }
            let fd = self.fd;
            let success =
                self.sim.files.get_mut(fd).map_or(false, |file_opt| {
                    *file_opt = None;
                    true
                });
            Poll::Ready(success)
        }
    }
}

// Random priority to increase "chaos" in simulation
type Task = Pin<Box<dyn Future<Output = ()>>>;

struct Simulator {
    files: Vec<Option<Vec<u8>>>,
    rng: rand::rngs::SmallRng,
}

impl Simulator {
    fn new(seed: u64) -> Self {
        Self {
            files: Vec::new(),
            rng: rand::rngs::SmallRng::seed_from_u64(seed),
        }
    }

    fn create_waker(&self) -> Waker {
        static VTABLE: RawWakerVTable = RawWakerVTable::new(
            |data| RawWaker::new(data, &VTABLE),
            |_| {},
            |_| {},
            |_| {},
        );

        unsafe {
            Waker::from_raw(RawWaker::new(
                std::ptr::null::<()>() as *const _,
                &VTABLE,
            ))
        }
    }

    fn run(&mut self) {
        let mut tasks: Vec<Task> = Vec::new();
        let mut fd = None;
        let mut buf = Vec::new();
        let mut bytes_written = None;
        let mut bytes_read = None;
        let mut success = None;

        tasks.push(Box::pin(async {
            let result = self.create().await;
            fd = Some(result);
            println!("Created file with FD: {}", result);
        }));

        let data = vec![42, 43, 44].into_boxed_slice();
        tasks.push(Box::pin(async {
            let result = self.append(fd.unwrap_or(0), data).await;
            bytes_written = Some(result);
            println!("Appended {} bytes", result);
        }));

        tasks.push(Box::pin(async {
            let result = self.read(&mut buf, fd.unwrap_or(0)).await;
            bytes_read = Some(result);
            println!("Read {} bytes: {:?}", result, buf);
        }));

        tasks.push(Box::pin(async {
            let result = self.delete(fd.unwrap_or(0)).await;
            success = Some(result);
            println!("Deleted FD {}: {}", fd.unwrap_or(0), result);
        }));

        let waker = self.create_waker();
        let mut context = Context::from_waker(&waker);

        while !tasks.is_empty() {
            let mut new_tasks = Vec::new();
            for mut task in tasks.drain(..) {
                match task.as_mut().poll(&mut context) {
                    Poll::Pending => new_tasks.push(task),
                    Poll::Ready(()) => {}
                }
            }
            tasks = new_tasks;
            tasks.shuffle(&mut self.rng); // Chaos via random polling
        }
    }
}

impl FileIO<usize> for Simulator {
    fn create(&mut self) -> impl Future<Output = usize> + '_ {
        let delay_steps = config::delay_steps(&mut self.rng);
        future::Create { delay_steps, sim: self }
    }

    fn read<'a>(
        &'a mut self,
        buf: &'a mut Vec<u8>,
        offset: usize,
    ) -> impl Future<Output = usize> + 'a {
        let delay_steps = config::delay_steps(&mut self.rng);
        future::Read { delay_steps, sim: self, buf, offset }
    }

    fn append(
        &mut self,
        fd: usize,
        data: Box<[u8]>,
    ) -> impl Future<Output = usize> + '_ {
        let delay_steps = config::delay_steps(&mut self.rng);
        future::Append { delay_steps, sim: self, fd, data: Some(data) }
    }

    fn delete(&mut self, fd: usize) -> impl Future<Output = bool> + '_ {
        let delay_steps = config::delay_steps(&mut self.rng);
        future::Delete { delay_steps, sim: self, fd }
    }
}

fn main() {
    let mut sim = Simulator::new(42);
    sim.run();
}
