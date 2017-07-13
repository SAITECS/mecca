module mecca.containers.producer_consumer;

import core.atomic;
import core.thread;
import std.string;


/******************************************************************************************************
 * Lock-free 1-to-many queue, either single consumer multi producers, or single producer multi
 * consumers.
 * The queue sacrifices fairness to efficiency. The size of the queue should be much larger than the
 * thread count to make sure all threads get the produce.
 * The consuming part is naturally not as important, as we're willing to "waste" threads as long as the
 * queue is constantly depleted.
 *
 * There is a STRONG assumption that the single part NEVER CHANGES ITS EXECUTING CPU CORE.
 * The single (producer/consumer) is not marked as shared, and may not be correct if that role is
 * moved to another core.
 ******************************************************************************************************/

struct _OneToManyQueue(T, size_t _capacity, bool singleConsumerMultiProducers) {
    static assert (is(T == U*, U));
    static assert (T.sizeof == (void*).sizeof);
    static assert ((void*).sizeof == ulong.sizeof);
    static assert (_capacity > 1);
    static assert ((_capacity & (_capacity-1)) == 0);

    enum capacity = _capacity;
    enum multiConsumersSingleProducer = !singleConsumerMultiProducers;

    private shared ulong readIndex;
    private shared ulong writeIndex;
    private shared ulong _effectiveCapacity;
    private shared ulong[capacity] arr;

    /// Must only be called from the main thread.
    void reset() {
        assert (thread_isMainThread());
        readIndex = 0;
        writeIndex = 0;
        _effectiveCapacity = capacity - 1;
        arr[] = 0;
    }

    /// Must only be called from the main thread.
    void addProducer() {
        assert (thread_isMainThread());
        assert (_effectiveCapacity > 0, "Too many producers. capacity: %s".format(capacity));
        static if (multiConsumersSingleProducer) {
            assert (_effectiveCapacity == capacity - 1, "Only a single producer can register");
        }

        atomicOp!"-="(_effectiveCapacity, 1);
    }

    /// Must only be called from the main thread.
    void removeProducer() {
        assert (thread_isMainThread());

        static if (multiConsumersSingleProducer) {
            assert (_effectiveCapacity == capacity - 2, "No producers registered");
        }
        atomicOp!"+="(_effectiveCapacity, 1);
    }

    @property bool isFull() const nothrow {
        // This has the same version for multi consumer and multi producers.
        // * For multi producers the readIndex may not have updated, so the worst to happen
        //   is that a producer will not produce, and will just try again later
        // * For multi consumers, since there is a single producer thread with the correct value
        //
        // Note that this assumes that there are no pointers around from cycles that are separated by more
        // than one pointer wraparound. Given that we are using ulongs, this is a solid assumption in
        // practice, even if theoritically a bit unsound in terms of the memory model.
        const ridx = atomicLoad!(MemoryOrder.raw)(readIndex);
        const widx = atomicLoad!(MemoryOrder.raw)(writeIndex);

        return atomicLoad!(MemoryOrder.raw)(_effectiveCapacity) <= (widx - ridx);
    }

    @property size_t effectiveCapacity() const nothrow {
        return _effectiveCapacity;
    }

    static private ubyte phaseOf(ulong idx) pure nothrow @safe {
        pragma(inline, true);
        static if (singleConsumerMultiProducers) {
            return (~(idx / capacity)) & 1;
        }
        else {
            return (idx / capacity) & 1;
        }
    }

    version(unittest) void sanity() {
        static if (singleConsumerMultiProducers) {
            const ridx = atomicLoad!(MemoryOrder.raw)(readIndex);
            const widx = atomicLoad!(MemoryOrder.raw)(writeIndex);
            assert(ridx <= widx, "writeIndex %d < readIndex %d".format(ridx, widx));
        }
    }

    bool pop(out T ptr) {
        version (unittest) {
            sanity();
            scope(exit) sanity();
        }

        // A raw load is fine in either case. For a single consumer, this is obviously up to date.
        // For multiple consumers, we will do a sequentially consistent cas() to claim a slot later
        // anyway, so the worst thing that can happen is that we needlessly wait for produce for
        // some time.
        const ridx = atomicLoad!(MemoryOrder.raw)(readIndex);

        static if (singleConsumerMultiProducers) {
            // Relaxed memory order is fine here, we will synchronize with the data store by virtue
            // of the acquire read of phase below.
            const widx = atomicLoad!(MemoryOrder.raw)(writeIndex);

            if (widx == ridx) {
                return false;
            }
            if (atomicLoad!(MemoryOrder.acq)(arr[ridx % capacity]) >> 63 != phaseOf(ridx)) {
                return false;
            }

            ptr = cast(T)((arr[ridx % capacity] << 1) >> 1);
            atomicStore!(MemoryOrder.raw)(readIndex, ridx + 1);
        }
        else {
            // Because incrementing writeIndex is the only thing the producer gives us to synchronize
            // with it storing the new data. To make the "no new data" case a bit cheaper on platforms
            // where acquire loads are expensive, the initial check could be done using a relaxed load
            // and an acquire barrier could be inserted after the slot has ben claimed.
            const widx = atomicLoad!(MemoryOrder.acq)(writeIndex);

            if (widx <= ridx) {
                return false;
            }

            // Try to claim the slot for reading.
            if (!cas(&readIndex, ridx, ridx + 1)) {
                return false;
            }

            ptr = cast(T)((arr[ridx % capacity] << 1) >> 1);

            // We have read the data, so toggle the phase to allow the producer to write to this slot
            // when it arrives at it the next time around.
            const nextPhase = ulong(1 - phaseOf(ridx)) << 63;
            atomicStore!(MemoryOrder.rel)(arr[ridx % capacity], nextPhase);
        }
        return true;
    }

    bool push(T ptr) {
        assert (cast(ulong)ptr >> 63 == 0, "MSB of ptr must be clear");
        assert (_effectiveCapacity < capacity - 1, "No producers have registered");

        version (unittest) {
            sanity();
            scope(exit) sanity();
        }

        if (isFull()) {
            return false;
        }
        static if (singleConsumerMultiProducers) {
            const widx = atomicOp!"+="(writeIndex, 1) - 1;
            const phase = phaseOf(widx);
            assert(atomicLoad!(MemoryOrder.acq)(arr[widx % capacity]) >> 63 != phase,
                   "Phase is already correct for new produce. widx %s arr[%d].phase = %d".format(
                          widx, widx % capacity, phase));

            const value = (ulong(phase) << 63) | cast(ulong)ptr;
            atomicStore!(MemoryOrder.rel)(arr[widx % capacity], value);
        }
        else {
            // We are the only one modifying the producer pointer, no synchronization needed.
            const widx = atomicLoad!(MemoryOrder.raw)(writeIndex);
            const phase = phaseOf(widx);

            // Make sure that the phase is back to "produce" mode.
            if (atomicLoad!(MemoryOrder.acq)(arr[widx % capacity]) >> 63 != phase) {
                // We have wrapped and the consumers have not read the data yet.
                return false;
            }

            const value = (ulong(phase) << 63) | cast(ulong)ptr;
            atomicStore!(MemoryOrder.raw)(arr[widx % capacity], value);
            atomicStore!(MemoryOrder.rel)(writeIndex, widx + 1);
        }
        return true;
    }
}

alias SCMPQueue(T, size_t capacity) = _OneToManyQueue!(T, capacity, true);
alias MCSPQueue(T, size_t capacity) = _OneToManyQueue!(T, capacity, false);

//debug = longrun;

unittest {
    import std.stdio;
    import core.exception;

    // start by creating a single thread with many producers
    SCMPQueue!(void*, 4) q;
    q.reset();
    void* a;
    assert(q.effectiveCapacity == 3, format("expected capacity of 3 found %d", q.effectiveCapacity));
    q.addProducer();
    assert(q.effectiveCapacity == 2);
    assert(!q.isFull());
    assert(!q.pop(a));
    assert(q.push(cast(void*)1));
    assert(q.push(cast(void*)2));
    assert(q.isFull(), format("capacity %d widx %d ridx %d isFull %d",
                              q.effectiveCapacity, q.writeIndex, q.readIndex, q.isFull));
    assert(q.pop(a));
    assert(cast(ulong)a == 1);
    assert(q.pop(a));
    assert(cast(ulong)a == 2);
    assert(!q.pop(a));

    SCMPQueue!(void*, 128) q2;
    q2.reset();

    int totalIter = 100;
    void produceNumbers(int initial) {
        //writeln("will produce from ", initial, " to ", initial + total);
        foreach(num; initial .. initial + totalIter) {
            while(!q2.push(cast(void*)num)) { }
        }
        //writeln("\nFinished producing from ", initial, " to ", initial + total);
    }

    debug(longrun) {
        enum numProducers = 120;
    } else {
        enum numProducers = 24;
    }

    class ProducerThread : Thread {
        int producerId;
        this (int id) {
            producerId = id;
            super(&run, 512 * 1024);
        }

    private:
        void run() {
            try {
                produceNumbers(producerId * totalIter);
            } catch (AssertError e) {
                writeln("\n\n Caught assertion ", e);
            }
        }
    }
    //writeln("Going to create producers");
    Thread[numProducers] producerThreads;
    foreach(i ; 0 .. numProducers) {
        q2.addProducer();
        assert(q2.effectiveCapacity == 127 - i - 1);
        producerThreads[i] = new ProducerThread(i);
    }
    foreach(i ; 0 .. numProducers) {
        producerThreads[i].start();
    }

    ulong[] popped;
    //writeln("Going to start consuming, max capacity is ", q2.effectiveCapacity);
    foreach(i; 0 .. numProducers*totalIter) {
        while(!q2.pop(a)) {}
        popped ~= cast(ulong)a;
    }

    foreach(i ; 0 .. numProducers) {
        producerThreads[i].join();
    }

    // TODO: join back all threads, make sure the arr is empty
    assert(q2.readIndex == q2.writeIndex,
           format("After all the work, arr is not empty. consumer %d producer %d",
                  q2.readIndex, q2.writeIndex));


    assert(popped.length == numProducers * totalIter);
    import std.algorithm;
    import std.range;
    foreach (i ; 0 .. numProducers) {
        //writefln("Will look for x between %d and %d", totalIter *i , totalIter*(i+1));
        auto some = popped
            .filter!(x => ( totalIter * i <= x) && (x < (i+1) * totalIter ))
            .array;
        //writefln("Array for %d is %s", i, some);
        assert(some.length == totalIter, format("Received invalid length %d != %d", some.length, totalIter ));
        auto calc = iota( totalIter* i, (i+1) *totalIter).array;
        assert(some == calc,
               format("Did not receive correct result %s != %s", some,calc ));
    }

    //writeln("\n\n Multi Consumers: spawning threads");
    // Now going to test multi consumer single producer case
    MCSPQueue!(void*, 16) mcq;
    mcq.reset();
    assert(mcq.effectiveCapacity == 15);
    mcq.addProducer();
    assert(mcq.effectiveCapacity == 14);


    debug(longrun) {
        enum numConsumers = 1000; // 1000 consumers for 16 slots queue
        enum producedElementNum = 100_000;
    } else {
        enum numConsumers = 100; // 100 consumers for 16 slots queue
        enum producedElementNum = 1_000;
    }

    shared( shared(ulong)[])[numConsumers] consumedData;
    shared bool stillRunning = true;

    class ConsumerThread : Thread {
        int consumerId;
        this(int _consumerId) {
            consumerId = _consumerId;
            super(&run, 512 * 1024);
        }

    private:
        void run() {
            // This is the actual code. Just consume messages until requested to
            // stop
            try {
                void* a;
                while (stillRunning) {
                    foreach(i ; 0 .. 2000) {
                        if(mcq.pop(a)) {
                            consumedData[consumerId] ~= cast(ulong)a;
                        }
                    }
                }
                if(mcq.pop(a)) {
                    consumedData[consumerId] ~= cast(ulong)a;
                }
            } catch (AssertError e) { // The thread.join shoule also throw, but just in case...
                writeln("\n\n Caught assertion ", e);
            }
        }
    }

    ConsumerThread[numConsumers] threads;
    foreach(i; 0 .. numConsumers) {
        threads[i] = new ConsumerThread(i);
        threads[i].start();
    }

    //writeln("All threads are running. Going to produce values: ", producedElementNum);
    foreach (i ; 0 .. producedElementNum) {
        while(!mcq.push(cast(void*)i)) {}
    }
    stillRunning = false;
    //writeln("Finished producing values, will wait for threads to join");
    foreach(i ; 0 .. numConsumers) {
        threads[i].join();
    }

    //writeln("Now will make sure data is correct");

    ulong[] result;
    foreach(l; consumedData) {
        foreach(d; l) {
            result ~= d;
        }
    }

    assert(result.length == producedElementNum, format("Total result length is not correct. Expected %d found %d", producedElementNum, result.length));
    result.sort();
    foreach(i; 0 .. producedElementNum) {
        assert(result[i] == i,
               format("result at location %d is %d", i, result[i]));
    }

    //writeln("Done");
}

struct DuplexQueue(T, size_t capacity) {
    MCSPQueue!(T, capacity) inputs;
    SCMPQueue!(T, capacity) outputs;

    void reset() {
        inputs.reset();
        inputs.addProducer();
        outputs.reset();
    }

    //
    // submit
    //
    bool pushInput(T ptr) {
        pragma(inline, true);
        //assert (thread_isMainThread());
        return inputs.push(ptr);
    }
    bool popOutput(out T ptr) {
        pragma(inline, true);
        //assert (thread_isMainThread());
        return outputs.pop(ptr);
    }
    void addWorker() {
        pragma(inline, true);
        outputs.addProducer();
    }
    void removeWorker() {
        pragma(inline, true);
        outputs.removeProducer();
    }

    //
    // worker-thread APIs
    //
    bool popInput(out T ptr) {
        pragma(inline, true);
        return inputs.pop(ptr);
    }
    bool pushOutput(T ptr) {
        pragma(inline, true);
        return outputs.push(ptr);
    }
}

unittest {
    import std.stdio;

    DuplexQueue!(void*, 512) dq;
    dq.reset();
    enum void* POISON = cast(void*)0x7fff_ffff_ffff_ffffUL;

    enum ulong numElems = 200_000;
    ulong inputsSum;
    ulong outputsSum;

    class Worker: Thread {
        this() {
            super(&run, 512*1024);
        }

        void run() {
            while (true) {
                void* p;
                if (dq.popInput(p)) {
                    //writeln("RI ", cast(ulong)p);

                    if (p is POISON) {
                        break;
                    }

                    while (!dq.pushOutput(p)) {}
                    //writeln("WO ", cast(ulong)p);
                }
            }
        }
    }

    Worker[17] workers;
    foreach(ref worker; workers) {
        worker = new Worker();
        dq.addWorker();
        worker.start();
    }

    void fetchReplies() {
        void* p;
        while (dq.popOutput(p)) {
            //writeln("RO ", cast(ulong)p);
            assert (p !is POISON);
            outputsSum += cast(ulong)p;
        }
    }

    for (ulong i = 1; i <= numElems;) {
        if (dq.pushInput(cast(void*)i)) {
            //writeln("WI ", i);
            inputsSum += i;
            i++;
        }
        fetchReplies();
    }

    for (int numPosions = 0; numPosions < workers.length;) {
        if (dq.pushInput(POISON)) {
            //writeln("poisoning ", numPosions);
            numPosions++;
        }
        fetchReplies();
    }

    foreach(worker; workers) {
        //writeln("joining worker");
        worker.join(true);
    }

    foreach(i; 0 .. 50) {
        fetchReplies();
    }

    auto computedSum = ((1+numElems) * numElems)/2;
    assert (computedSum == inputsSum, "comp %s != inp %s".format(computedSum, inputsSum));
    assert (outputsSum == inputsSum, "out %s != inp %s".format(outputsSum, inputsSum));
    //writeln("done2");
}

