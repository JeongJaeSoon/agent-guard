package local

import "golang.org/x/sys/unix"

// fionread is FIONREAD from <sys/filio.h>, _IOR('f', 127, int); x/sys does
// not export it for Darwin.
const fionread = 0x4004667f

// PipeWaiting returns how many bytes a pipe (or socket) holds unread, without
// reading them.
func PipeWaiting(fd int) (int, error) {
	return unix.IoctlGetInt(fd, fionread)
}
