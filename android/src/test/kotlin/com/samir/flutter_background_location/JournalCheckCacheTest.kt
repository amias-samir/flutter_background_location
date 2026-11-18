package com.samir.flutter_background_location

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class JournalCheckCacheTest {
    private val identity = JournalFileIdentity(4096, 1_000L, 0, 1_000L)

    @Test
    fun `a verified journal closed unchanged skips the next scan once`() {
        val cache = JournalCheckCache()
        cache.markVerified()
        cache.onClosed(identity)
        assertTrue(cache.canSkip(identity))
        cache.onOpened()
        assertFalse(cache.canSkip(identity), "the record is used by one reopen only")
    }

    @Test
    fun `a changed or missing file is always checked`() {
        val cache = JournalCheckCache()
        cache.markVerified()
        cache.onClosed(identity)
        assertFalse(cache.canSkip(identity.copy(databaseBytes = 8192)))
        assertFalse(cache.canSkip(identity.copy(walModifiedAt = 2_000L)))
        assertFalse(cache.canSkip(null))
    }

    @Test
    fun `an unchecked or failed store is checked on reopen`() {
        val unchecked = JournalCheckCache()
        unchecked.onClosed(identity)
        assertFalse(unchecked.canSkip(identity))

        val failed = JournalCheckCache()
        failed.markVerified()
        failed.forget()
        failed.onClosed(identity)
        assertFalse(failed.canSkip(identity))
    }

    private fun assertFalse(condition: Boolean, message: String) =
        org.junit.Assert.assertFalse(message, condition)
}
