// SPDX-FileCopyrightText: 2022-2023 TriliTech <contact@trili.tech>
// SPDX-FileCopyrightText: 2023 Marigold <contact@marigold.dev>
// SPDX-FileCopyrightText: 2022 Nomadic Labs <contact@nomadic-labs.com>
//
// SPDX-License-Identifier: MIT

//! Definition of **Runtime** api that is callable from *safe* rust.
//!
//! Includes blanket implementation for all types implementing [SmartRollupCore].

#[cfg(feature = "alloc")]
use alloc::vec::Vec;
use tezos_smart_rollup_core::{SmartRollupCore, PREIMAGE_HASH_SIZE};

#[cfg(feature = "alloc")]
use crate::input::Message;
use crate::metadata::RollupMetadata;
#[cfg(feature = "alloc")]
use crate::path::{OwnedPath, Path, RefPath, PATH_MAX_SIZE};
#[cfg(not(feature = "alloc"))]
use crate::path::{Path, RefPath};
use crate::{Error, METADATA_SIZE};
#[cfg(feature = "alloc")]
use tezos_smart_rollup_core::smart_rollup_core::ReadInputMessageInfo;

#[derive(Copy, Eq, PartialEq, Clone, Debug)]
/// Errors that may be returned when called [Runtime] methods.
pub enum RuntimeError {
    /// Attempted to read from/delete a key that does not exist.
    PathNotFound,
    /// Attempted to get a subkey at an out-of-bounds index.
    StoreListIndexOutOfBounds,
    /// Errors returned by the host functions
    HostErr(Error),
}

/// Returned by [`Runtime::store_has`] - specifies whether a path has a value or is a prefix.
#[derive(Debug, Copy, Clone, Eq, PartialEq)]
pub enum ValueType {
    /// The path has a value, but is not a prefix to further values.
    Value,
    /// The path is a prefix to further values, but has no value.
    Subtree,
    /// The path has a value, and is a prefix to further values.
    ValueWithSubtree,
}

/// Safe wrappers for host capabilities.
///
/// **NB**:
/// - methods that take `&self` will not cause changes to the runtime state.
/// - methods taking `&mut self` are expected to cause changes - either to *input*,
///   *output* or *durable storage*.
pub trait Runtime {
    /// Write contents of the given slice to output.
    fn write_output(&mut self, from: &[u8]) -> Result<(), RuntimeError>;

    /// Write message to debug log.
    fn write_debug(&self, msg: &str);

    /// Read the next input from the global inbox.
    ///
    /// Returns `None` if no message was available. This happens when the kernel has
    /// finished reading the inbox at the current level.
    ///
    /// The kernel will need to yield to the next level to recieve more input.
    #[cfg(feature = "alloc")]
    fn read_input(&mut self) -> Result<Option<Message>, RuntimeError>;

    /// Returns whether a given path exists in storage.
    fn store_has<T: Path>(&self, path: &T) -> Result<Option<ValueType>, RuntimeError>;

    /// Read up to `max_bytes` from the given path in storage, starting `from_offset`.
    #[cfg(feature = "alloc")]
    fn store_read<T: Path>(
        &self,
        path: &T,
        from_offset: usize,
        max_bytes: usize,
    ) -> Result<Vec<u8>, RuntimeError>;

    /// Read up to `buffer.len()` from the given path in storage.
    ///
    /// Value is read starting `from_offset`.
    ///
    /// The total bytes read is returned.
    /// If the returned value `n` is `n < buffer.len()`, then only the first `n`
    /// bytes of the buffer will have been written too.
    fn store_read_slice<T: Path>(
        &self,
        path: &T,
        from_offset: usize,
        buffer: &mut [u8],
    ) -> Result<usize, RuntimeError>;

    /// Write the bytes given by `src` to storage at `path`, starting `at_offset`.
    fn store_write<T: Path>(
        &mut self,
        path: &T,
        src: &[u8],
        at_offset: usize,
    ) -> Result<(), RuntimeError>;

    /// Delete `path` from storage.
    fn store_delete<T: Path>(&mut self, path: &T) -> Result<(), RuntimeError>;

    /// Count the number of subkeys under `prefix`.
    ///
    /// See [SmartRollupCore::store_list_size].
    fn store_count_subkeys<T: Path>(&self, prefix: &T) -> Result<i64, RuntimeError>;

    /// Get the subkey under `prefix` at `index`.
    ///
    /// # Returns
    /// Returns the subkey as an [OwnedPath], **excluding** the `prefix`.
    #[cfg(feature = "alloc")]
    fn store_get_subkey<T: Path>(
        &self,
        prefix: &T,
        index: i64,
    ) -> Result<OwnedPath, RuntimeError>;

    /// Move one part of durable storage to a different location
    ///
    /// See [SmartRollupCore::store_move].
    fn store_move(
        &mut self,
        from_path: &impl Path,
        to_path: &impl Path,
    ) -> Result<(), RuntimeError>;

    /// Copy one part of durable storage to a different location
    ///
    /// See [SmartRollupCore::store_copy].
    fn store_copy(
        &mut self,
        from_path: &impl Path,
        to_path: &impl Path,
    ) -> Result<(), RuntimeError>;

    /// Reveal pre-image from a hash of size `PREIMAGE_HASH_SIZE` in bytes.
    ///
    /// N.B. in future, multiple hashing schemes will be supported, but for
    /// now the kernels only support hashes of type `Reveal_hash`, which is
    /// a 32-byte Blake2b hash with a prefix-byte of `0`.
    fn reveal_preimage(
        &self,
        hash: &[u8; PREIMAGE_HASH_SIZE],
        destination: &mut [u8],
    ) -> Result<usize, RuntimeError>;

    /// Return the size of value stored at `path`
    fn store_value_size(&self, path: &impl Path) -> Result<usize, RuntimeError>;

    /// Mark the kernel for reboot.
    ///
    /// If the kernel is marked for reboot, it will continue
    /// reading inbox messages for the current level next time `kernel_run` runs.
    /// If the inbox contains no more messages, the kernel will still continue at
    /// the current inbox level until it is no longer marked for reboot.
    ///
    /// If the kernel is _not_ marked for reboot, it will skip the rest of the inbox
    /// for the current level and _yield_. It will then continue at the next inbox
    /// level.
    ///
    /// The kernel is given a maximum number of reboots per level. The number of reboots remaining
    /// is written to `/readonly/kernel/env/reboot_counter` (little endian i32).
    ///
    /// If the kernel exceeds this, it is forced to yield to the next level (and a flag is set at
    /// `/readonly/kernel/env/too_many_reboot` to indicate this happened.
    fn mark_for_reboot(&mut self) -> Result<(), RuntimeError>;

    /// Returns [RollupMetadata]
    fn reveal_metadata(&self) -> Result<RollupMetadata, RuntimeError>;
}

const REBOOT_PATH: RefPath = RefPath::assert_from(b"/kernel/env/reboot");

impl<Host> Runtime for Host
where
    Host: SmartRollupCore,
{
    fn write_output(&mut self, output: &[u8]) -> Result<(), RuntimeError> {
        let result_code =
            unsafe { SmartRollupCore::write_output(self, output.as_ptr(), output.len()) };

        match Error::wrap(result_code) {
            Ok(_) => Ok(()),
            Err(e) => Err(RuntimeError::HostErr(e)),
        }
    }

    fn write_debug(&self, msg: &str) {
        unsafe { Host::write_debug(msg.as_ptr(), msg.len()) };
    }

    #[cfg(feature = "alloc")]
    fn read_input(&mut self) -> Result<Option<Message>, RuntimeError> {
        use core::mem::MaybeUninit;
        use tezos_smart_rollup_core::MAX_INPUT_MESSAGE_SIZE;

        let mut buffer = Vec::with_capacity(MAX_INPUT_MESSAGE_SIZE);

        let mut message_info = MaybeUninit::<ReadInputMessageInfo>::uninit();

        let bytes_read = unsafe {
            SmartRollupCore::read_input(
                self,
                message_info.as_mut_ptr(),
                buffer.as_mut_ptr(),
                MAX_INPUT_MESSAGE_SIZE,
            )
        };

        let bytes_read = match Error::wrap(bytes_read) {
            Ok(0) => return Ok(None),
            Ok(size) => size,
            Err(e) => return Err(RuntimeError::HostErr(e)),
        };

        let ReadInputMessageInfo { level, id } = unsafe {
            buffer.set_len(bytes_read);
            message_info.assume_init()
        };

        // level & id are guaranteed to be positive
        let input = Message::new(level as u32, id as u32, buffer);

        Ok(Some(input))
    }

    fn store_has<T: Path>(&self, path: &T) -> Result<Option<ValueType>, RuntimeError> {
        let result =
            unsafe { SmartRollupCore::store_has(self, path.as_ptr(), path.size()) };

        let value_type = Error::wrap(result).map_err(RuntimeError::HostErr)? as i32;

        match value_type {
            tezos_smart_rollup_core::VALUE_TYPE_NONE => Ok(None),
            tezos_smart_rollup_core::VALUE_TYPE_VALUE => Ok(Some(ValueType::Value)),
            tezos_smart_rollup_core::VALUE_TYPE_SUBTREE => Ok(Some(ValueType::Subtree)),
            tezos_smart_rollup_core::VALUE_TYPE_VALUE_WITH_SUBTREE => {
                Ok(Some(ValueType::ValueWithSubtree))
            }
            _ => Err(RuntimeError::HostErr(Error::GenericInvalidAccess)),
        }
    }

    #[cfg(feature = "alloc")]
    fn store_read<T: Path>(
        &self,
        path: &T,
        from_offset: usize,
        max_bytes: usize,
    ) -> Result<Vec<u8>, RuntimeError> {
        use tezos_smart_rollup_core::MAX_FILE_CHUNK_SIZE;

        check_path_has_value(self, path)?;

        let mut buffer = Vec::with_capacity(max_bytes);

        unsafe {
            #![allow(clippy::uninit_vec)]
            // SAFETY:
            // Setting length here gives access, from safe rust, to
            // uninitialised bytes.
            //
            // This is safe as these bytes will not be read by `store_read_slice`.
            // Rather, store_read_slice writes to the (part) of the slice, and
            // returns the total bytes written.
            buffer.set_len(usize::min(MAX_FILE_CHUNK_SIZE, max_bytes));

            let size = self.store_read_slice(path, from_offset, &mut buffer)?;

            // SAFETY:
            // We ensure that we set the length of the vector to the
            // total bytes written - ie so that only the bytes that are now
            // initialised, are accessible.
            buffer.set_len(size);
        }

        Ok(buffer)
    }

    fn store_read_slice<T: Path>(
        &self,
        path: &T,
        from_offset: usize,
        buffer: &mut [u8],
    ) -> Result<usize, RuntimeError> {
        let result = unsafe {
            self.store_read(
                path.as_ptr(),
                path.size(),
                from_offset,
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };

        match Error::wrap(result) {
            Ok(i) => Ok(i),
            Err(e) => Err(RuntimeError::HostErr(e)),
        }
    }

    fn store_write<T: Path>(
        &mut self,
        path: &T,
        src: &[u8],
        at_offset: usize,
    ) -> Result<(), RuntimeError> {
        let result_code = unsafe {
            SmartRollupCore::store_write(
                self,
                path.as_ptr(),
                path.size(),
                at_offset,
                src.as_ptr(),
                src.len(),
            )
        };
        match Error::wrap(result_code) {
            Ok(_) => Ok(()),
            Err(e) => Err(RuntimeError::HostErr(e)),
        }
    }

    fn store_delete<T: Path>(&mut self, path: &T) -> Result<(), RuntimeError> {
        check_path_exists(self, path)?;

        let res =
            unsafe { SmartRollupCore::store_delete(self, path.as_ptr(), path.size()) };
        match Error::wrap(res) {
            Ok(_) => Ok(()),
            Err(e) => Err(RuntimeError::HostErr(e)),
        }
    }

    fn store_count_subkeys<T: Path>(&self, path: &T) -> Result<i64, RuntimeError> {
        let count =
            unsafe { SmartRollupCore::store_list_size(self, path.as_ptr(), path.size()) };

        if count >= 0 {
            Ok(count)
        } else {
            Err(RuntimeError::HostErr(count.into()))
        }
    }

    #[cfg(feature = "alloc")]
    fn store_get_subkey<T: Path>(
        &self,
        path: &T,
        index: i64,
    ) -> Result<OwnedPath, RuntimeError> {
        let size = self.store_count_subkeys(path)?;

        if index >= 0 && index < size {
            store_get_subkey_unchecked(self, path, index)
        } else {
            Err(RuntimeError::StoreListIndexOutOfBounds)
        }
    }

    fn store_move(
        &mut self,
        from_path: &impl Path,
        to_path: &impl Path,
    ) -> Result<(), RuntimeError> {
        check_path_exists(self, from_path)?;

        let res = unsafe {
            SmartRollupCore::store_move(
                self,
                from_path.as_ptr(),
                from_path.size(),
                to_path.as_ptr(),
                to_path.size(),
            )
        };
        match Error::wrap(res) {
            Ok(_) => Ok(()),
            Err(e) => Err(RuntimeError::HostErr(e)),
        }
    }

    fn store_copy(
        &mut self,
        from_path: &impl Path,
        to_path: &impl Path,
    ) -> Result<(), RuntimeError> {
        check_path_exists(self, from_path)?;

        let res = unsafe {
            SmartRollupCore::store_copy(
                self,
                from_path.as_ptr(),
                from_path.size(),
                to_path.as_ptr(),
                to_path.size(),
            )
        };
        match Error::wrap(res) {
            Ok(_) => Ok(()),
            Err(e) => Err(RuntimeError::HostErr(e)),
        }
    }

    fn reveal_preimage(
        &self,
        hash: &[u8; PREIMAGE_HASH_SIZE],
        buffer: &mut [u8],
    ) -> Result<usize, RuntimeError> {
        let res = unsafe {
            SmartRollupCore::reveal_preimage(
                self,
                hash.as_ptr(),
                PREIMAGE_HASH_SIZE,
                buffer.as_mut_ptr(),
                buffer.len(),
            )
        };
        match Error::wrap(res) {
            Ok(size) => Ok(size),
            Err(e) => Err(RuntimeError::HostErr(e)),
        }
    }

    fn reveal_metadata(&self) -> Result<RollupMetadata, RuntimeError> {
        let mut destination = [0u8; METADATA_SIZE];
        let res = unsafe {
            SmartRollupCore::reveal_metadata(
                self,
                destination.as_mut_ptr(),
                destination.len(),
            )
        };
        match Error::wrap(res) {
            Ok(_) => Ok(RollupMetadata::from(destination)),
            Err(e) => Err(RuntimeError::HostErr(e)),
        }
    }

    fn store_value_size(&self, path: &impl Path) -> Result<usize, RuntimeError> {
        check_path_exists(self, path)?;
        let res = unsafe {
            SmartRollupCore::store_value_size(self, path.as_ptr(), path.size())
        };
        match Error::wrap(res) {
            Ok(size) => Ok(size),
            Err(e) => Err(RuntimeError::HostErr(e)),
        }
    }

    fn mark_for_reboot(&mut self) -> Result<(), RuntimeError> {
        self.store_write(&REBOOT_PATH, &[0_u8], 0)
    }
}

#[cfg(feature = "alloc")]
fn check_path_has_value<T: Path>(
    runtime: &impl Runtime,
    path: &T,
) -> Result<(), RuntimeError> {
    if let Ok(Some(ValueType::Value | ValueType::ValueWithSubtree)) =
        runtime.store_has(path)
    {
        Ok(())
    } else {
        Err(RuntimeError::PathNotFound)
    }
}

fn check_path_exists<T: Path>(
    runtime: &impl Runtime,
    path: &T,
) -> Result<(), RuntimeError> {
    if let Ok(Some(_)) = runtime.store_has(path) {
        Ok(())
    } else {
        Err(RuntimeError::PathNotFound)
    }
}

#[cfg(feature = "alloc")]
fn store_get_subkey_unchecked(
    host: &impl SmartRollupCore,
    path: &impl Path,
    index: i64,
) -> Result<OwnedPath, RuntimeError> {
    let max_size = PATH_MAX_SIZE - path.size();
    let mut buffer = Vec::with_capacity(max_size);

    unsafe {
        let bytes_written = host.store_list_get(
            path.as_ptr(),
            path.size(),
            index,
            buffer.as_mut_ptr(),
            max_size,
        );

        match Error::wrap(bytes_written) {
            Ok(bytes_written) => {
                buffer.set_len(bytes_written);

                Ok(OwnedPath::from_bytes_unchecked(buffer))
            }
            Err(e) => Err(RuntimeError::HostErr(e)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Runtime, RuntimeError, PREIMAGE_HASH_SIZE};
    use crate::{
        input::Message,
        metadata::RollupMetadata,
        path::{OwnedPath, Path, RefPath, PATH_MAX_SIZE},
        Error, METADATA_SIZE,
    };
    use std::slice::{from_raw_parts, from_raw_parts_mut};
    use test_helpers::*;
    use tezos_smart_rollup_core::{
        smart_rollup_core::MockSmartRollupCore, MAX_INPUT_MESSAGE_SIZE, MAX_OUTPUT_SIZE,
    };

    const READ_SIZE: usize = 80;

    #[test]
    fn given_output_written_then_ok() {
        // Arrange
        let mut mock = MockSmartRollupCore::new();
        let output = "just a bit of output we want to write";

        mock.expect_write_output()
            .withf(|ptr, len| {
                let slice = unsafe { from_raw_parts(*ptr, *len) };

                output.as_bytes() == slice
            })
            .return_const(0);

        // Act
        let result = mock.write_output(output.as_bytes());

        // Assert
        assert_eq!(Ok(()), result);
    }

    #[test]
    fn given_output_too_large_then_err() {
        // Arrange
        let mut mock = MockSmartRollupCore::new();

        let output = [b'a'; MAX_OUTPUT_SIZE + 1];

        mock.expect_write_output().return_once(|ptr, len| {
            let slice = unsafe { from_raw_parts(ptr, len) };

            assert!(slice.iter().all(|b| b == &b'a'));
            assert_eq!(MAX_OUTPUT_SIZE + 1, slice.len());

            Error::InputOutputTooLarge.code()
        });

        // Act
        let result = mock.write_output(output.as_slice());

        // Assert
        assert_eq!(
            Err(RuntimeError::HostErr(Error::InputOutputTooLarge)),
            result
        );
    }

    #[test]
    fn read_input_returns_none_when_nothing_read() {
        // Arrange
        let mut mock = MockSmartRollupCore::new();
        mock.expect_read_input().return_const(0_i32);

        // Act
        let outcome = mock.read_input();

        // Assert
        assert_eq!(Ok(None), outcome);
    }

    #[test]
    fn read_message_input_with_size_max_bytes() {
        // Arrange
        let level = 5;
        let id = 12908;
        let byte = b'?';
        const FRACTION: usize = 1;

        let mut mock = read_input_with(level, id, byte, FRACTION);

        // Act
        let outcome = mock.read_input();

        // Assert
        let expected = Message::new(
            level,
            id,
            Box::new([byte; MAX_INPUT_MESSAGE_SIZE / FRACTION]).to_vec(),
        );

        assert_eq!(Ok(Some(expected)), outcome);
    }

    #[test]
    fn store_has_existing_return_true() {
        // Arrange
        let mut mock = MockSmartRollupCore::new();
        let existing_path = RefPath::assert_from("/an/Existing/path".as_bytes());

        mock.expect_store_has()
            .withf(move |ptr, size| {
                let bytes = unsafe { from_raw_parts(*ptr, *size) };
                existing_path.as_bytes() == bytes
            })
            .return_const(tezos_smart_rollup_core::VALUE_TYPE_VALUE);

        // Act
        let result = mock.store_has(&existing_path);

        assert!(matches!(result, Ok(Some(_))));
    }

    fn mock_path_not_existing(path_bytes: Vec<u8>) -> MockSmartRollupCore {
        let mut mock = MockSmartRollupCore::new();

        mock.expect_store_has()
            .withf(move |ptr, size| {
                let bytes = unsafe { from_raw_parts(*ptr, *size) };
                path_bytes == bytes
            })
            .return_const(tezos_smart_rollup_core::VALUE_TYPE_NONE);

        mock
    }

    #[test]
    fn store_has_not_existing_returns_false() {
        // Arrange
        let path_bytes = String::from("/does/not.exist").into_bytes();
        let non_existent_path: OwnedPath = RefPath::assert_from(&path_bytes).into();

        let mock = mock_path_not_existing(path_bytes);

        // Act
        let result = mock.store_has(&non_existent_path);

        // Assert
        assert!(matches!(result, Ok(None)));
    }

    #[test]
    fn store_read_max_bytes() {
        // Arrange
        const FRACTION: usize = 1;
        const PATH: RefPath<'static> = RefPath::assert_from("/a/simple/path".as_bytes());
        const OFFSET: usize = 5;

        let mut mock = mock_path_exists(PATH.as_bytes());
        mock.expect_store_read()
            .withf(|path_ptr, path_size, from_offset, _, max_bytes| {
                let slice = unsafe { from_raw_parts(*path_ptr, *path_size) };

                READ_SIZE == *max_bytes
                    && PATH.as_bytes() == slice
                    && OFFSET == *from_offset
            })
            .return_once(|_, _, _, buf_ptr, _| {
                let stored_bytes = [b'2'; READ_SIZE / FRACTION];
                let buffer = unsafe { from_raw_parts_mut(buf_ptr, READ_SIZE / FRACTION) };
                buffer.copy_from_slice(&stored_bytes);
                (READ_SIZE / FRACTION).try_into().unwrap()
            });

        // Act
        let result = mock.store_read(&PATH, OFFSET, READ_SIZE);

        // Assert
        let expected = std::iter::repeat(b'2').take(READ_SIZE / FRACTION).collect();

        assert_eq!(Ok(expected), result);
    }

    #[test]
    fn store_read_lt_max_bytes() {
        // Arrange
        const FRACTION: usize = 5;
        const PATH: RefPath<'static> = RefPath::assert_from("/a/simple/path".as_bytes());
        const OFFSET: usize = 10;

        let mut mock = mock_path_exists(PATH.as_bytes());
        mock.expect_store_read()
            .withf(|path_ptr, path_size, from_offset, _, max_bytes| {
                let slice = unsafe { from_raw_parts(*path_ptr, *path_size) };

                READ_SIZE == *max_bytes
                    && PATH.as_bytes() == slice
                    && OFFSET == *from_offset
            })
            .return_once(|_, _, _, buf_ptr, _| {
                let stored_bytes = [b'Z'; READ_SIZE / FRACTION];
                let buffer = unsafe { from_raw_parts_mut(buf_ptr, READ_SIZE / FRACTION) };
                buffer.copy_from_slice(&stored_bytes);
                (READ_SIZE / FRACTION).try_into().unwrap()
            });

        // Act
        let result = mock.store_read(&PATH, OFFSET, READ_SIZE);

        // Assert
        let expected = std::iter::repeat(b'Z').take(READ_SIZE / FRACTION).collect();

        assert_eq!(Ok(expected), result);
    }

    #[test]
    fn store_read_path_not_found() {
        // Arrange
        let bytes = "/a/2nd/PATH.which/doesnt/exist".as_bytes().to_vec();
        let path: OwnedPath = RefPath::assert_from(&bytes).into();
        let offset = 25;

        let mock = mock_path_not_existing(bytes);

        // Act
        let result = mock.store_read(&path, offset, READ_SIZE);

        // Assert
        assert_eq!(Err(RuntimeError::PathNotFound), result);
    }

    #[test]
    fn store_write_ok() {
        // Arrange
        const PATH: RefPath<'static> = RefPath::assert_from("/a/simple/path".as_bytes());
        const OUTPUT: &[u8] = "One two three four five".as_bytes();
        const OFFSET: usize = 12398;

        let mut mock = MockSmartRollupCore::new();
        mock.expect_store_write()
            .withf(|path_ptr, path_size, at_offset, src_ptr, src_size| {
                let path_slice = unsafe { from_raw_parts(*path_ptr, *path_size) };
                let output_slice = unsafe { from_raw_parts(*src_ptr, *src_size) };

                OUTPUT == output_slice
                    && PATH.as_bytes() == path_slice
                    && OFFSET == *at_offset
            })
            .return_const(0);

        // Act
        let result = mock.store_write(&PATH, OUTPUT, OFFSET);

        // Assert
        assert_eq!(Ok(()), result);
    }

    #[test]
    fn store_write_too_large() {
        // Arrange
        const PATH: RefPath<'static> = RefPath::assert_from("/a/simple/path".as_bytes());
        const OUTPUT: &[u8] = "once I saw a fish alive".as_bytes();
        const OFFSET: usize = 0;

        let mut mock = MockSmartRollupCore::new();
        mock.expect_store_write()
            .withf(|path_ptr, path_size, at_offset, src_ptr, src_size| {
                let path_slice = unsafe { from_raw_parts(*path_ptr, *path_size) };
                let output_slice = unsafe { from_raw_parts(*src_ptr, *src_size) };

                OUTPUT == output_slice
                    && PATH.as_bytes() == path_slice
                    && OFFSET == *at_offset
            })
            .return_const(Error::InputOutputTooLarge.code());

        // Act
        let result = mock.store_write(&PATH, OUTPUT, OFFSET);

        // Assert
        assert_eq!(
            Err(RuntimeError::HostErr(Error::InputOutputTooLarge)),
            result
        );
    }

    #[test]
    fn store_delete() {
        // Arrange
        const PATH: RefPath<'static> =
            RefPath::assert_from("/a/2nd/PATH.which/does/exist".as_bytes());

        let mut mock = mock_path_exists(PATH.as_bytes());
        mock.expect_store_delete()
            .withf(|ptr, size| {
                let slice = unsafe { from_raw_parts(*ptr, *size) };

                PATH.as_bytes() == slice
            })
            .return_const(0);

        // Act
        let result = mock.store_delete(&PATH);

        // Assert
        assert_eq!(Ok(()), result);
    }

    #[test]
    fn store_delete_path_not_found() {
        // Arrange
        let bytes = String::from("/a/2nd/PATH.which/doesnt/exist").into_bytes();
        let path: OwnedPath = RefPath::assert_from(&bytes).into();

        let mut mock = mock_path_not_existing(bytes);

        // Act
        let result = mock.store_delete(&path);

        // Assert
        assert_eq!(Err(RuntimeError::PathNotFound), result);
    }

    #[test]
    fn store_count_subkeys() {
        // Arrange
        const PATH: RefPath<'static> =
            RefPath::assert_from("/prefix/of/other/keys".as_bytes());

        let subkey_count = 14;

        let mut mock = MockSmartRollupCore::new();

        mock.expect_store_list_size()
            .withf(|ptr, size| {
                let slice = unsafe { from_raw_parts(*ptr, *size) };

                PATH.as_bytes() == slice
            })
            .return_const(subkey_count);

        // Act
        let result = mock.store_count_subkeys(&PATH);

        // Assert
        assert_eq!(Ok(subkey_count), result);
    }

    #[test]
    fn store_get_subkey() {
        // Arrange
        const PATH: RefPath<'static> =
            RefPath::assert_from("/prefix/of/other/paths".as_bytes());

        let subkey_index = 14;
        let subkey_count = 20;
        let buffer_size = PATH_MAX_SIZE - PATH.size();

        let mut mock = MockSmartRollupCore::new();
        mock.expect_store_list_size()
            .withf(|ptr, size| {
                let slice = unsafe { from_raw_parts(*ptr, *size) };

                PATH.as_bytes() == slice
            })
            .return_const(subkey_count);

        mock.expect_store_list_get()
            .withf(move |path_ptr, path_size, index, _, max_bytes| {
                let slice = unsafe { from_raw_parts(*path_ptr, *path_size) };

                PATH.as_bytes() == slice
                    && subkey_index == *index
                    && buffer_size == *max_bytes
            })
            .return_once(|_, _, _, buf_ptr, _| {
                let path_bytes = "/short/suffix".as_bytes();
                let buffer = unsafe { from_raw_parts_mut(buf_ptr, path_bytes.len()) };
                buffer.copy_from_slice(path_bytes);

                path_bytes.len().try_into().unwrap()
            });

        // Act
        let result = mock.store_get_subkey(&PATH, subkey_index);

        // Assert
        let expected = RefPath::assert_from("/short/suffix".as_bytes()).into();

        assert_eq!(Ok(expected), result);
    }

    #[test]
    fn store_get_subkey_index_out_of_range_upper() {
        // Arrange
        const PATH: RefPath<'static> =
            RefPath::assert_from("/prefix/of/other/paths".as_bytes());

        let subkey_index = 0;
        let subkey_count = 0;

        let mut mock = MockSmartRollupCore::new();
        mock.expect_store_list_size()
            .withf(|ptr, size| {
                let slice = unsafe { from_raw_parts(*ptr, *size) };

                PATH.as_bytes() == slice
            })
            .return_const(subkey_count);

        // Act
        let result = mock.store_get_subkey(&PATH, subkey_index);

        // Assert
        assert_eq!(Err(RuntimeError::StoreListIndexOutOfBounds), result);
    }

    #[test]
    fn store_get_subkey_index_out_of_range_lower() {
        // Arrange
        const PATH: RefPath<'static> =
            RefPath::assert_from("/prefix/of/other/paths".as_bytes());

        let subkey_index = -1;
        let subkey_count = 5;

        let mut mock = MockSmartRollupCore::new();
        mock.expect_store_list_size()
            .withf(|ptr, size| {
                let slice = unsafe { from_raw_parts(*ptr, *size) };

                PATH.as_bytes() == slice
            })
            .return_const(subkey_count);

        // Act
        let result = mock.store_get_subkey(&PATH, subkey_index);

        // Assert
        assert_eq!(Err(RuntimeError::StoreListIndexOutOfBounds), result);
    }

    #[test]
    fn reveal_preimage_ok() {
        let mut mock = MockSmartRollupCore::new();

        mock.expect_reveal_preimage()
            .withf(|hash_addr, hash_len, _dest_addr, max_bytes| {
                let hash = unsafe { from_raw_parts(*hash_addr, *hash_len) };
                hash_len == &PREIMAGE_HASH_SIZE
                    && hash == [5; PREIMAGE_HASH_SIZE]
                    && *max_bytes == 55
            })
            .return_once(|_, _, destination_address, _| {
                let revealed_bytes = [b'!'; 50];
                let buffer = unsafe { from_raw_parts_mut(destination_address, 50) };
                buffer.copy_from_slice(&revealed_bytes);
                50
            });
        let mut buffer = [0; 55];
        // Act
        let result =
            mock.reveal_preimage(&[5; PREIMAGE_HASH_SIZE], buffer.as_mut_slice());

        // Assert
        assert_eq!(Ok(50), result);
    }

    #[test]
    fn store_value_size() {
        let mut mock = MockSmartRollupCore::new();
        const PATH: RefPath<'static> = RefPath::assert_from(b"/prefix/of/other/paths");
        let size = 256_usize;
        mock.expect_store_has()
            .return_const(tezos_smart_rollup_core::VALUE_TYPE_VALUE);
        mock.expect_store_value_size()
            .return_const(i32::try_from(size).unwrap());
        let value_size = mock.store_value_size(&PATH);
        assert_eq!(size, value_size.unwrap());
    }

    #[test]
    fn store_value_size_path_not_found() {
        let mut mock = MockSmartRollupCore::new();
        const PATH: RefPath<'static> = RefPath::assert_from(b"/prefix/of/other/paths");
        mock.expect_store_has()
            .return_const(tezos_smart_rollup_core::VALUE_TYPE_NONE);

        assert_eq!(
            Err(RuntimeError::PathNotFound),
            mock.store_value_size(&PATH)
        );
    }

    #[test]
    fn reveal_metadata_ok() {
        let mut mock = MockSmartRollupCore::new();
        let metadata_bytes = [
            // sr1 as 20 bytes
            b'M', 165, 28, b']', 231, 161, 205, 212, 148, 193, b'[', b'S', 129, b'^', 31,
            170, b'L', 26, 150, 202, // origination level as 4 bytes
            0, 0, 0, 42,
        ];
        let expected_metadata = RollupMetadata::from(metadata_bytes);

        mock.expect_reveal_metadata()
            .return_once(move |destination_address, _| {
                let buffer =
                    unsafe { from_raw_parts_mut(destination_address, METADATA_SIZE) };
                buffer.copy_from_slice(&metadata_bytes.clone());
                METADATA_SIZE as i32
            });

        // Act
        let result = mock.reveal_metadata().unwrap();

        // Assert
        assert_eq!(expected_metadata, result);
    }

    mod test_helpers {
        use tezos_smart_rollup_core::smart_rollup_core::ReadInputMessageInfo;
        use tezos_smart_rollup_core::MAX_INPUT_MESSAGE_SIZE;

        use super::MockSmartRollupCore;
        use std::slice::{from_raw_parts, from_raw_parts_mut};

        pub fn mock_path_exists(path_bytes: &'static [u8]) -> MockSmartRollupCore {
            let mut mock = MockSmartRollupCore::new();

            mock.expect_store_has()
                .withf(move |ptr, size| {
                    let bytes = unsafe { from_raw_parts(*ptr, *size) };
                    path_bytes == bytes
                })
                .return_const(tezos_smart_rollup_core::VALUE_TYPE_VALUE);

            mock
        }

        pub fn read_input_with(
            level: u32,
            id: u32,
            fill_with: u8,
            fill_fraction: usize,
        ) -> MockSmartRollupCore {
            let mut mock = MockSmartRollupCore::new();

            let write_bytes = MAX_INPUT_MESSAGE_SIZE / fill_fraction;

            let input_bytes = std::iter::repeat(fill_with)
                .take(write_bytes)
                .collect::<Box<_>>();

            mock.expect_read_input().return_once(
                move |message_info_arg, buffer_arg, max_bytes_arg| {
                    assert_eq!(max_bytes_arg, MAX_INPUT_MESSAGE_SIZE);

                    unsafe {
                        std::ptr::write(
                            message_info_arg,
                            ReadInputMessageInfo {
                                level: level as i32,
                                id: id as i32,
                            },
                        );
                        let buffer = from_raw_parts_mut(buffer_arg, write_bytes);
                        buffer.copy_from_slice(input_bytes.as_ref());
                    }
                    write_bytes.try_into().unwrap()
                },
            );

            mock
        }
    }
}
