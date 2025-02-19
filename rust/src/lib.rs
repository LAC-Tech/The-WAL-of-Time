#[no_std]
extern crate alloc;

use alloc::vec::Vec;

mod os {
    use crate::task;
    pub enum IoArgs<'a, FD> {
        Create,
        Read { fd: FD, buf: Vec<u8>, offset: usize },
        Append { fd: FD, data: &'a [u8] },
        Delete(FD),
    }

    #[derive(Debug)]
    pub enum IoRetVal<FD: core::fmt::Debug> {
        Create(FD),
        Read(usize),
        Append(usize),
        Delete(bool),
    }

    pub struct Input<'a, FD> {
        pub task_id: task::ID,
        pub args: IoArgs<'a, FD>,
    }

    pub struct Output<FD: core::fmt::Debug> {
        pub task_id: task::ID,
        pub ret_val: IoRetVal<FD>,
    }

    pub trait OS<'msg> {
        type FD: core::fmt::Debug;
        fn new(on_receive: impl FnMut(Output<Self::FD>)) -> Self;
        fn send(&mut self, msg: Input<'msg, Self::FD>);
    }
}

mod task {
    pub type ID = u64;

    // We always know what type the function is at this point
    pub union Callback<UserCtx, FD> {
        pub create: fn(ctx: &mut UserCtx, fd: FD),
    }

    pub struct Task<'ctx, UserCtx, FD> {
        /// Pointer to some mutable context, so the callback can effect
        /// the outside world.
        /// What Baker/Hewitt called "proper environment", AFAICT
        pub ctx: &'ctx mut UserCtx,
        /// Executed when the OS Output is available.
        /// First param will always be the context
        pub callback: Callback<UserCtx, FD>,
    }
}

struct AsyncRuntime<'ctx, UserCtx, FD> {
    tasks: Vec<task::Task<'ctx, UserCtx, FD>>,
    recycled: Vec<task::ID>,
}

impl<'ctx, UserCtx, FD> AsyncRuntime<'ctx, UserCtx, FD> {
    fn new() -> Self { Self { tasks: vec![], recycled: vec![] } }

    fn add(&mut self, t: task::Task<'ctx, UserCtx, FD>) -> task::ID {
        match self.recycled.pop() {
            Some(task_id) => {
                self.tasks[task_id as usize] = t;
                task_id
            }
            None => {
                let task_id = self.tasks.len();
                self.tasks.push(t);
                task_id as task::ID
            }
        }
    }

    fn remove(
        &mut self,
        task_id: task::ID,
    ) -> &mut task::Task<'ctx, UserCtx, FD> {
        self.recycled.push(task_id);
        self.tasks.get_mut(task_id as usize).expect("task id to be valid")
    }
}

struct DB<'ctx, UserCtx, FD, OS> {
    async_runtime: AsyncRuntime<'ctx, UserCtx, FD>,
    os: OS,
}

impl<'ctx, UserCtx, FD: core::fmt::Debug, OS: os::OS<'ctx, FD = FD>>
    DB<'ctx, UserCtx, FD, OS>
{
    fn new() -> Self {
        let mut async_runtime = AsyncRuntime::new();
        let on_receive = |os::Output { task_id, ret_val }| match ret_val {
            os::IoRetVal::Create(fd) => {
                let t = async_runtime.remove(task_id);
                let on_create = unsafe { t.callback.create };
                on_create(t.ctx, fd);
            }
            _ => panic!("TODO: handle receiving '{:?}' from OS", ret_val),
        };

        let os = OS::new(on_receive);

        Self { async_runtime, os }
    }

    fn os_receive(&mut self, os::Output { task_id, ret_val }: os::Output<FD>) {
        match ret_val {
            os::IoRetVal::Create(fd) => {
                let t = self.async_runtime.remove(task_id);
                let on_create = unsafe { t.callback.create };
                on_create(t.ctx, fd);
            }
            _ => panic!("TODO: handle receiving '{:?}' from OS", ret_val),
        }
    }

    fn create_stream(
        &mut self,
        ctx: &'ctx mut UserCtx,
        cb: fn(ctx: &mut UserCtx, fd: FD),
    ) {
        let task_id = self
            .async_runtime
            .add(task::Task { ctx, callback: task::Callback { create: cb } });

        self.os.send(os::Input { task_id, args: os::IoArgs::Create })
    }
}
