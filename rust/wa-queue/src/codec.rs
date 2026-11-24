//! The queue's on-Kv record format: length-prefixed fields, big-endian integers, no dependencies.
//!
//! A record is decoded whole or not at all (`QueueError::Corrupt`), so a half-written value is
//! visible as damage instead of being read as a different job.

use crate::{JobId, JobState, QueueError};

pub(crate) type R<T> = Result<T, QueueError>;

pub(crate) fn u32b(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_be_bytes());
}

pub(crate) fn u64b(out: &mut Vec<u8>, v: u64) {
    out.extend_from_slice(&v.to_be_bytes());
}

pub(crate) fn i64b(out: &mut Vec<u8>, v: i64) {
    out.extend_from_slice(&v.to_be_bytes());
}

pub(crate) fn bytesb(out: &mut Vec<u8>, v: &[u8]) {
    u32b(out, v.len() as u32);
    out.extend_from_slice(v);
}

pub(crate) fn strb(out: &mut Vec<u8>, v: &str) {
    bytesb(out, v.as_bytes());
}

pub(crate) fn opt_strb(out: &mut Vec<u8>, v: Option<&str>) {
    match v {
        Some(text) => {
            out.push(1);
            strb(out, text);
        }
        None => out.push(0),
    }
}

pub(crate) fn opt_i64b(out: &mut Vec<u8>, v: Option<i64>) {
    match v {
        Some(n) => {
            out.push(1);
            i64b(out, n);
        }
        None => out.push(0),
    }
}

pub(crate) fn opt_bytesb(out: &mut Vec<u8>, v: Option<&[u8]>) {
    match v {
        Some(bytes) => {
            out.push(1);
            bytesb(out, bytes);
        }
        None => out.push(0),
    }
}

pub(crate) struct Reader<'a> {
    buf: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    pub(crate) fn new(buf: &'a [u8]) -> Self {
        Self { buf, at: 0 }
    }

    fn take(&mut self, n: usize) -> R<&'a [u8]> {
        let end = self
            .at
            .checked_add(n)
            .ok_or_else(|| QueueError::Corrupt("length overflow".into()))?;
        if end > self.buf.len() {
            return Err(QueueError::Corrupt("truncated record".into()));
        }
        let slice = &self.buf[self.at..end];
        self.at = end;
        Ok(slice)
    }

    pub(crate) fn u8(&mut self) -> R<u8> {
        Ok(self.take(1)?[0])
    }

    pub(crate) fn u32(&mut self) -> R<u32> {
        let b = self.take(4)?;
        Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }

    pub(crate) fn u64(&mut self) -> R<u64> {
        let b = self.take(8)?;
        Ok(u64::from_be_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }

    pub(crate) fn i64(&mut self) -> R<i64> {
        let b = self.take(8)?;
        Ok(i64::from_be_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }

    pub(crate) fn bytes(&mut self) -> R<Vec<u8>> {
        let len = self.u32()? as usize;
        Ok(self.take(len)?.to_vec())
    }

    pub(crate) fn string(&mut self) -> R<String> {
        String::from_utf8(self.bytes()?)
            .map_err(|_| QueueError::Corrupt("record is not utf-8".into()))
    }

    pub(crate) fn opt_string(&mut self) -> R<Option<String>> {
        match self.u8()? {
            0 => Ok(None),
            1 => Ok(Some(self.string()?)),
            n => Err(QueueError::Corrupt(format!("bad option tag {n}"))),
        }
    }

    pub(crate) fn opt_i64(&mut self) -> R<Option<i64>> {
        match self.u8()? {
            0 => Ok(None),
            1 => Ok(Some(self.i64()?)),
            n => Err(QueueError::Corrupt(format!("bad option tag {n}"))),
        }
    }

    pub(crate) fn opt_bytes(&mut self) -> R<Option<Vec<u8>>> {
        match self.u8()? {
            0 => Ok(None),
            1 => Ok(Some(self.bytes()?)),
            n => Err(QueueError::Corrupt(format!("bad option tag {n}"))),
        }
    }

    pub(crate) fn job_id(&mut self) -> R<JobId> {
        Ok(JobId(self.u64()?))
    }

    pub(crate) fn finished(&self) -> R<()> {
        if self.at == self.buf.len() {
            Ok(())
        } else {
            Err(QueueError::Corrupt("trailing bytes in record".into()))
        }
    }
}

pub(crate) fn state_code(state: JobState) -> u8 {
    match state {
        JobState::Ready => 0,
        JobState::Leased => 1,
        JobState::Done => 2,
        JobState::Dead => 3,
        JobState::Expired => 4,
    }
}

pub(crate) fn state_from(code: u8) -> R<JobState> {
    match code {
        0 => Ok(JobState::Ready),
        1 => Ok(JobState::Leased),
        2 => Ok(JobState::Done),
        3 => Ok(JobState::Dead),
        4 => Ok(JobState::Expired),
        n => Err(QueueError::Corrupt(format!("bad job state {n}"))),
    }
}
