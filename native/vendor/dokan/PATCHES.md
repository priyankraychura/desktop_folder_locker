# Changes to dokan 0.3.1+dokan206

This is [dokan-rust](https://github.com/dokan-dev/dokan-rust) 0.3.1
(MIT license, see `LICENSE`), vendored because of one bug that crashes the
file system, with these changes:

- **Requests without a context.** Dokany also sends requests for handles
  that `create_file` never opened (for example on the volume, `\\.\V:`),
  with a null context. The original glue turned that into a null
  reference (undefined behaviour; a crash in debug builds, and in any
  handler that looks at the context). Now:
  - `OperationInfo::try_context()` returns `None` for such handles;
  - `FileSystemHandler::default_context()` (new, `None` by default) lets
    the handler supply a context for them;
  - without one, the requests fail with `STATUS_INVALID_DEVICE_REQUEST`
    (`STATUS_NOT_IMPLEMENTED` for the security and stream requests, so
    Dokany uses its defaults), flushing succeeds, and `cleanup` and
    `close_file` are skipped.
- Allowed the `unsupported_calling_conventions` lint: the callbacks stay
  `extern "stdcall"` to match the function types of dokan-sys (on 64-bit
  Windows, stdcall means the C ABI, which is what Dokany calls).
- Removed: the examples, the tests that need a running Dokany, and the
  dev-dependencies.
