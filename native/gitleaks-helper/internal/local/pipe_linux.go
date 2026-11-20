package local

import "golang.org/x/sys/unix"

// PipeWaiting returns how many bytes a pipe (or socket) holds unread, without
// reading them (FIONREAD, named TIOCINQ on Linux).
func PipeWaiting(fd int) (int, error) {
	return unix.IoctlGetInt(fd, unix.TIOCINQ)
}
