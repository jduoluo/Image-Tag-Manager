package com.example.image_tag_manager;

import java.util.List;
import java.util.Objects;

/** MediaStore compatibility operation. Prechecks are not an atomic no-replace primitive. */
final class MediaStoreRenameOperation {
    static final class Row {
        final String uri;
        final String path;
        final String name;
        Row(String uri, String path, String name) {
            this.uri = uri; this.path = path; this.name = name;
        }
    }
    interface Backend {
        default boolean samePath(String first, String second) { return Objects.equals(first, second); }
        default boolean matchesSource(String source, Row row) {
            return samePath(source, row.path) && source.endsWith("/" + row.name);
        }
        Row rowForPath(String path);
        Row rowForUri(String uri);
        String identityOrNull(String path);
        List<String> directoryNames(String source);
        int update(Row before, String targetName);
    }
    static final class UncertainResultException extends IllegalStateException {
        UncertainResultException(String message, Throwable cause) { super(message, cause); }
    }
    static void rename(Backend backend, String source, String target, String expectedId) {
        String targetName = target.substring(target.lastIndexOf('/') + 1);
        Row before = backend.rowForPath(source);
        require(before != null && backend.matchesSource(source, before), "媒体库中的源名称或路径已变化，请刷新后重新预演");
        require(expectedId.equals(backend.identityOrNull(source)), "源文件身份已变化，未执行改名");
        List<String> names = backend.directoryNames(source);
        require(names != null, "无法读取目录名称，未执行改名");
        require(names.stream().noneMatch(name -> name.equalsIgnoreCase(targetName)),
                "目标名称已被文件或目录占用，未执行改名：" + targetName);
        // Include unindexed entries and check again immediately before asking the provider.
        require(backend.identityOrNull(target) == null, "目标路径已被占用，未执行改名");
        require(expectedId.equals(backend.identityOrNull(source)), "执行前源文件身份已变化，未执行改名");
        Row current = backend.rowForUri(before.uri);
        require(current != null && backend.matchesSource(source, current) && before.name.equals(current.name),
                "执行前媒体库记录已变化，未执行改名");
        int count = -1;
        RuntimeException failure = null;
        try {
            count = backend.update(before, targetName);
        } catch (RuntimeException error) {
            failure = error;
        }
        Row after;
        try {
            after = backend.rowForUri(before.uri);
            boolean exact = after != null && before.uri.equals(after.uri) &&
                    backend.samePath(target, after.path) && targetName.equals(after.name) &&
                    expectedId.equals(backend.identityOrNull(target)) &&
                    backend.identityOrNull(source) == null;
            // Some providers throw after a successful write: the actual file and row decide.
            if (exact && (count == 1 || failure != null)) return;
            boolean unchanged = after != null && backend.matchesSource(source, after) &&
                    before.name.equals(after.name) && expectedId.equals(backend.identityOrNull(source));
            String detail = "系统媒体库改名未通过核对（更新数量 " + count + "）。实际记录：" +
                    (after == null ? "无法读取" : after.path + "；名称：" + after.name);
            if (failure != null) detail += "；系统原因：" + Objects.toString(failure.getMessage(), failure.getClass().getSimpleName());
            if (unchanged) {
                throw new IllegalStateException("文件仍在原名。" + detail, failure);
            }
            throw new UncertainResultException(detail + "。已停止，不自动接受系统换名或继续操作；请核对事务记录。", failure);
        } catch (UncertainResultException error) {
            throw error;
        } catch (RuntimeException error) {
            // A verified unchanged state can use the normal first-stage rollback policy.
            if (error instanceof IllegalStateException && error.getMessage().startsWith("文件仍在原名。")) throw error;
            throw new UncertainResultException("系统调用后无法可靠核对文件，已停止并保留记录：" +
                    Objects.toString(error.getMessage(), error.getClass().getSimpleName()), error);
        }
    }
    private static void require(boolean accepted, String message) {
        if (!accepted) throw new IllegalStateException(message);
    }
}
