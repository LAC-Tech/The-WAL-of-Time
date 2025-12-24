use std::{os::fd::AsRawFd, ptr::null};

use io_uring::{IoUring, opcode, types};
use lib;

struct AsyncIO {
    io_uring: io_uring::IoUring,
}

impl AsyncIO {
    fn new() -> std::io::Result<Self> {
        io_uring::IoUring::new(32).map(|io_uring| Self { io_uring })
    }

    fn io_uring_fd(&self) -> i32 {
        self.io_uring.as_raw_fd()
    }
}

impl lib::io::AsyncIO for AsyncIO {
    type Err = std::io::Error;

    fn submit(&mut self) -> std::io::Result<usize> {
        self.io_uring.submit()
    }

    /*
    fn wait_for_res(&mut self) -> Result<lib::io::Res, Self::Err> {
        let cqe = self.io_uring.completion()
    }
    */

    fn accept(
        &mut self,
        server_fd: i32,
        user_data: impl Into<u64>,
    ) -> Result<(), Self::Err> {
        let accept = opcode::AcceptMulti::new(types::Fd(server_fd))
            .build()
            .user_data(user_data.into());

        unsafe {
            self.io_uring.submission().push(&accept)?;
        }

        Ok(())
    }
}

fn main() {
    println!("Hello, world!");
}
