#ifndef RUNNER_SAFE_RENAME_CHANNEL_H_
#define RUNNER_SAFE_RENAME_CHANNEL_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

#include <flutter/binary_messenger.h>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateSafeRenameChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SAFE_RENAME_CHANNEL_H_
