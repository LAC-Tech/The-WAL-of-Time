//! Glue layer between a core and a particular OS
//! They are OS independent, but also represent quite low level operations
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UserData {
    Accept,
    Recv { client_fd: i32 },
    Send { buf_id: u16 },
    Close,
}

const _: () = assert!(core::mem::size_of::<UserData>() == 8);

impl From<UserData> for u64 {
    fn from(val: UserData) -> u64 {
        unsafe { core::mem::transmute(val) }
    }
}

impl From<u64> for UserData {
    fn from(val: u64) -> Self {
        unsafe { core::mem::transmute(val) }
    }
}

pub struct Res {
    pub user_data: UserData,
    pub more: bool,
    pub buf_id: u16,
    pub result: i32,
}

#[derive(Clone, Copy)]
pub enum Req {
    Illegal,
    Recv { client_fd: i32 },
    Send { client_fd: i32, buf_id: u16, len: usize },
    Close { client_fd: i32 },
    Accept { server_fd: i32 },
    ReleaseBuf { buf_id: u16 },
}

pub trait BufRing {
    fn get(&self, buf_id: u16) -> &[u8];
    fn release(&mut self, buf_id: u16);
}

pub trait AsyncIO {
    type Err;
    fn recv(&mut self, user_data: impl Into<u64>) -> Result<(), Self::Err>;
    fn send(
        &mut self,
        client_fd: i32,
        data: &[u8],
        user_data: impl Into<u64>,
    ) -> Result<(), Self::Err>;

    fn close(
        &mut self,
        client_fd: i32,
        user_data: impl Into<u64>,
    ) -> Result<(), Self::Err>;
    fn accept(
        &mut self,
        server_fd: i32,
        user_data: impl Into<u64>,
    ) -> Result<(), Self::Err>;

    fn wait_for_res(&mut self) -> Result<Res, Self::Err>;
    fn submit(&mut self) -> Result<u32, Self::Err>;
}

#[cfg(test)]
mod tests {
    use super::*;

    use arbtest::arbtest;

    #[test]
    fn user_data_serde() {
        arbtest(|u| {
            for expected in [
                UserData::Accept,
                UserData::Recv { client_fd: u.arbitrary()? },
                UserData::Send { buf_id: u.arbitrary()? },
            ] {
                let actual = UserData::from(u64::from(expected));
                assert_eq!(actual, expected);
            }

            Ok(())
        });
    }
}
