package com.example.image_tag_manager;

import java.util.*;
import java.util.function.Function;

/** Snapshot of actual directory spellings; case equivalence is never identity proof. */
final class MediaSourceNames {
    private final Map<String, List<String>> names = new HashMap<>();
    MediaSourceNames(List<String> actualNames) {
        for (String name : actualNames) names.computeIfAbsent(key(name), ignored -> new ArrayList<>()).add(name);
    }
    private static String key(String name) { return name.toUpperCase(Locale.ROOT); }

    String resolve(String mediaName, String pathName, String expectedId, Function<String, String> identity) {
        return resolve(mediaName, pathName, expectedId, identity, ignored -> null);
    }
    String resolve(String mediaName, String pathName, String expectedId, Function<String, String> identity,
            Function<String, String> readableIdentity) {
        if (!mediaName.equalsIgnoreCase(pathName)) {
            throw new IllegalStateException("媒体记录名称与路径不一致：" + mediaName + "；路径文件名：" + pathName);
        }
        List<String> candidates = names.getOrDefault(key(pathName), Collections.emptyList());
        // The metadata step already read identity through this exact path.
        if (candidates.contains(pathName)) return pathName;
        if (candidates.isEmpty() && mediaName.equals(pathName) &&
                expectedId.equals(readableIdentity.apply(pathName))) return pathName;
        String resolved = null;
        for (String candidate : candidates) {
            if (!expectedId.equals(identity.apply(candidate))) continue;
            if (resolved != null) throw new IllegalStateException("存在多个同身份名称，无法确认原图：" + mediaName);
            resolved = candidate;
        }
        if (resolved != null) return resolved;
        throw new IllegalStateException("系统媒体记录与实际目录不一致：" + mediaName +
            (candidates.isEmpty() ? "；目录中未找到此文件" : "；目录中同名候选：" + String.join("、", candidates) + "，文件身份不一致"));
    }
}
