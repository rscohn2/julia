typealias PtrSize Int
const UVHandle = PtrSize
const IOStreamHandle = Ptr{Void}
localEventLoop() = ccall(:jl_local_event_loop,PtrSize,())
globalEventLoop() = ccall(:jl_global_event_loop,PtrSize,())

typealias Executable Union(Vector{ByteString},Function)

abstract AsyncStream <: Stream

type Cmd
    exec::Executable
end

type Cmds
    siblings::Set{Cmd}
    pipeline::Union(Bool,Cmds)
    Cmds() = new(Set{Cmd}(),false)
    Cmds(c::Cmd) = new(Set(c),false)
end

typealias StreamHandle Union(PtrSize,AsyncStream)

type Process
    handle::PtrSize
    in::StreamHandle
    out::StreamHandle
    err::StreamHandle
    exit_code::PtrSize
    term_signal::PtrSize
    Process(handle::PtrSize,in::StreamHandle,out::StreamHandle,err::StreamHandle)=new(handle,in,out,err,-1,-1)
    Process(handle::PtrSize,in::StreamHandle,out::StreamHandle)=Process(handle,in,out,0)
end

type Processes
    siblings::Set{Process}
    in::StreamHandle
    out::StreamHandle
    #pipeline::Processes
    Processes()=new(Set{Process}(),0,0)
end


typealias CmdsOrNot Union(Bool,Cmds)
typealias BufOrNot Union(Bool,IOStream)

type NamedPipe <: AsyncStream
    handle::PtrSize
    buf::BufOrNot
    closed::Bool
    NamedPipe(handle::PtrSize,buf::IOStream) = new(handle,buf,false)
    NamedPipe(handle::PtrSize) = new(handle,false,false)
end

type TTY <: AsyncStream
    handle::PtrSize
    buf::BufOrNot
    closed::Bool
end
typealias PipeOrNot Union(Bool,AsyncStream)

make_stdout_stream() = TTY(ccall(:jl_stdout, PtrSize, ()),memio(),false)

function _uv_tty2tty(handle::PtrSize)
    TTY(handle,memio(),false)
end

## SOCKETS ##

abstract Socket <: AsyncStream

type TcpSocket <: Socket
    handle::PtrSize
    buf::BufOrNot
    closed::Bool
    TcpSocket(handle::PtrSize)=new(handle,false,false)
end

type UdpSocket <: Socket
    handle::PtrSize
    buf::BufOrNot
    closed::Bool
    UdpSocket(handle::PtrSize)=new(handle,false,false)
end

function _init_buf(stream::AsyncStream)
    if(!isa(stream.buf,IOStream))
        stream.buf=memio()
    end
end

_jl_tcp_init(loop::PtrSize) = ccall(:jl_tcp_init,PtrSize,(PtrSize,),loop)
_jl_udp_init(loop::PtrSize) = ccall(:jl_udp_init,PtrSize,(PtrSize,),loop)

abstract IpAddr

type Ip4Addr <: IpAddr
    port::Uint16
    host::Uint32
end

type Ip6Addr <: IpAddr
    port::Uint16
    host::Array{Uint8,1} #this should be fixed at 16 bytes is fixed size arrays are implemented
    flow_info::Uint32
    scope::Uint32
end

_jl_listen(sock::AsyncStream,backlog::Int32,cb::Function) = ccall(:jl_listen,Int32,(PtrSize,Int32,Function),sock.handle,backlog,make_callback(cb))

_jl_tcp_bind(sock::TcpSocket,addr::Ip4Addr) = ccall(:jl_tcp_bind,Int32,(PtrSize,Uint32,Uint16),sock.handle,addr.host,addr.port)
_jl_tcp_connect(sock::TcpSocket,addr::Ip4Addr) = ccall(:jl_tcp_connect,Int32,(PtrSize,Uint32,Uint16,Function),sock.handle,addr.host,addr.port)

function connection_cb(handle::PtrSize, status::Int32)

end

function open_any_tcp_port(preferred_port::Uint16,cb::Function)
    socket = TcpSocket(_jl_tcp_init(globalEventLoop()));
    if(socket.handle==0)
        error("open_any_tcp_port: could not create socket")
    end
    addr = Ip4Addr(preferred_port,uint32(0)) #bind prefereed port on all adresses
    while _jl_tcp_bind(socket,addr)!=0
        addr.port+=1;
    end
    err = _jl_listen(socket,int32(4),connection_cb)
    if(err!=0)
        print(err)
        error("open_any_tcp_port: could not listen on socket")
    end
    return (addr.port,socket)
end

abstract AsyncWork

type SingleAsyncWork <: AsyncWork
    handle::PtrSize
    SingleAsyncWork(handle::PtrSize)=new(handle)
end

type IdleAsyncWork <: AsyncWork
    handle::PtrSize
end

type TimeoutAsyncWork <: AsyncWork
    handle::PtrSize
end

const dummySingleAsync = SingleAsyncWork(0)

function createSingleAsyncWork(loop::PtrSize,cb::Function)
    return SingleAsyncWork(ccall(:jl_make_async,PtrSize,(Ptr{PtrSize},Function),loop,cb))
end

function initIdleAsync(loop::PtrSize)
    IdleAsyncWork(ccall(:jl_idle_init,PtrSize,(PtrSize,),int(loop)))
end

function initTimeoutAsync(loop::PtrSize)
    TimeoutAsyncWork(ccall(:jl_timer_init,PtrSize,(PtrSize,),loop))
end

function startTimer(timer::TimeoutAsyncWork,cb::Function,timeout::Int64,repeat::Int64)
    ccall(:jl_timer_start,Int32,(PtrSize,Function,Int64,Int64),timer.handle,cb,timeout,repeat)
end

function stopTimer(timer::TimeoutAsyncWork)
    ccall(:jl_tier_stop,Int32,(PtrSize,),timer.handle)
end

assignIdleAsyncWork(work::IdleAsyncWork,cb::Function) = ccall(:jl_idle_start,PtrSize,(Ptr{PtrSize},Function),work.handle,cb)

function add_idle_cb(loop::PtrSize,cb::Function)
    work = initIdleAsyncWork(loop)
    assignIdleAsyncWork(work,cb)
    work
end

function queueAsync(work::SingleAsyncWork)
    ccall(:jl_async_send,Void,(Ptr{PtrSize},),work.handle)
end

# process status #
abstract ProcessStatus
type ProcessNotRun   <: ProcessStatus; end
type ProcessRunning  <: ProcessStatus; end
type ProcessExited   <: ProcessStatus; status::PtrSize; end
type ProcessSignaled <: ProcessStatus; signal::PtrSize; end
type ProcessStopped  <: ProcessStatus; signal::PtrSize; end

process_exited  (s::Process) = (s.exit_code != -1)
process_signaled(s::Process) = (s.term_signal > 0)
process_stopped (s::Process) = 0 #not supported by libuv. Do we need this?

process_exit_status(s::Process) = s.exit_code
process_term_signal(s::Process) = s.term_signal
process_stop_signal(s::Process) = 0 #not supported by libuv. Do we need this?

function process_status(s::PtrSize)
    process_exited  (s) ? ProcessExited  (process_exit_status(s)) :
    process_signaled(s) ? ProcessSignaled(process_term_signal(s)) :
    process_stopped (s) ? ProcessStopped (process_stop_signal(s)) :
    error("process status error")
end

## types

##event loop
function run_event_loop(loop::PtrSize)
    ccall(:jl_run_event_loop,Void,(Ptr{PtrSize},),loop)
end
run_event_loop() = run_event_loop(localEventLoop())

function break_one_loop(loop::PtrSize)
    ccall(:uv_break_one,Void,(Ptr{Void},),loop)
end

function process_events(loop::PtrSize)
    ccall(:jl_process_events,Void,(Ptr{PtrSize},),loop)
end
process_events() = process_events(localEventLoop())

##pipe functions

function make_pipe()
    NamedPipe(ccall(:jl_make_pipe,PtrSize,())) #make the pipe and unbuffered stream for now
end

function close(stream::AsyncStream)
    if(!stream.closed)
        ccall(:jl_close_uv,Void,(Ptr{PtrSize},),stream.handle)
        stream.closed=true
    end
end

##stream functions

function start_reading(stream::AsyncStream,cb::Function)
    ccall(:jl_start_reading,Bool,(Ptr{PtrSize},Ptr{Void},Function),stream.handle,stream.buf.ios,cb!=0?cb:C_NULL)
end
start_reading(stream::AsyncStream) = start_reading(stream,0)

function stop_reading(stream::AsyncStream,  cb::PtrSize)
    ccall(:jl_stop_reading,Bool.(Ptr{PtrSize},IOStreamHandle),cb)
end
stop_reading(stream::AsyncStream) = stop_reading(stream,0)

function readall(stream::AsyncStream)
start_reading(stream)
run_event_loop()
takebuf_string(stream.buf)
end

#show(p::Process) = print("Process")


function finish_read(pipe::NamedPipe)
    close(pipe) #handles to UV and ios will be invalid after this point
end

function finish_read(state::(NamedPipe,ByteString))
    finish_read(state...)
end

function end_process(p::Process,h::PtrSize,e::Int32, t::Int32)
    p.exit_code=e
    p.term_signal=t
end

function spawn(cmd::Cmd,in::PipeOrNot,out::PipeOrNot,exitcb::Function,closecb::Function,pp::Process)
    ptrs = _jl_pre_exec(cmd.exec);
    pp.handle=ccall(:jl_spawn, PtrSize, (Ptr{Uint8}, Ptr{Ptr{Uint8}}, Ptr{PtrSize}, Ptr{PtrSize}, Function,Function),ptrs[1], ptrs,isa(in,NamedPipe) ? in.handle : C_NULL, isa(out,NamedPipe) ? out.handle : C_NULL,exitcb,closecb)
    pp.in=isa(in,NamedPipe)?in:0
    pp.out=isa(out,NamedPipe)?out:0
    pp
end
spawn(cmd::Cmd,in::PipeOrNot,out::PipeOrNot,exitcb::Function,closecb::Function) = spawn(cmd,in,out,exitcb,closecb,Process(0,0,0,0))
spawn(cmd::Cmd,in::PipeOrNot,out::PipeOrNot,exitcb::Function) = spawn(cmd,in,out,exitcb,0,Process(0,0,0,0))
spawn(cmd::Cmd,in::PipeOrNot,out::PipeOrNot)=spawn(cmd,in,out,0)
spawn(cmd::Cmd,in::PipeOrNot)=spawn(cmd,in,false)
spawn(cmd::Cmd)=spawn(cmd,false,false,0)

function process_exited_chain(procs::Processes,h::PtrSize,e::Int32,t::Int32)
    for p in procs.siblings
        if(p.handle==h)
            p.exit_code=e
            p.term_signal=t
        end
    end
end

function process_closed_chain(procs::Processes)
    done=true
    for p in procs.siblings
        if(!process_exited(p))
            done=false
        end
    end
    if(done && procs.out!=0)
            close(procs.out)
    end
end

function spawn(cmds::Cmds,in::PipeOrNot,out::PipeOrNot)
    if(isa(cmds.pipeline,Cmds))
        n=make_pipe()
        spawn(cmds.pipeline,n,out)
    else
        n=out
    end
    procs = Processes()
    for c in cmds.siblings
        add(procs.siblings,spawn(c,in,n,make_callback((args...)->process_exited_chain(procs,args...)),make_callback((args...)->process_closed_chain(procs))))
    end
    #if(isa(n,AsyncStream))
        #start_reading(n)
    #end
    procs.out=isa(n,AsyncStream)?n:0
    procs.in=isa(in,NamedPipe)?in:0
    return procs
end
spawn(cmds::Cmds)=spawn(cmds,false,false)
spawn(cmds::Cmds,in::PipeOrNot)=spawn(cmds,in,false)


#returns a pipe to read from the last command in the pipelines
read_from(cmd::Cmd) = read_from(Cmds(cmd))
function read_from(cmds::Cmds)
    out=make_pipe()
    _init_buf(out) #create buffer for reading
    spawn(cmds,false,out);
    ccall(:jl_start_reading,Bool,(Ptr{PtrSize},Ptr{Void},Ptr{PtrSize}),out.handle,out.buf.ios,C_NULL)
    out
end

function change_readcb(stream::AsyncStream,readcb::Function)
    ccall(:jl_change_readcb,Int16,(PtrSize,Function),stream.handle,readcb)
end

write_to(cmd::Cmd) = write_to(Cmds(cmd))
function write_to(cmds::Cmds)
    in=make_pipe();
    spawn(cmds,in)
    in
end

readall(cmd::Cmd) = readall(Cmds(cmd))
function readall(cmds::Cmds)
    out=read_from(cmds)
    run_event_loop()
    return takebuf_string(out.buf)
end

function _contains_newline(bufptr::PtrSize,len::Int32)
    return (ccall(:memchr,Ptr{Uint8},(PtrSize,Int32,Uint),bufptr,'\n',len)!=C_NULL)
end


function linebuffer_cb(cb::Function,stream::AsyncStream,handle::PtrSize,nread::PtrSize,base::PtrSize,buflen::Int32)
    if(!isa(stream.buf,IOStream))
        error("Linebuffering only supported on membuffered ASyncStreams")
    end
    if(nread>0)
        #search for newline
        base=convert(Ptr{Uint8},base);
        pd::Ptr{Uint8} = ccall(:memchr,Ptr{Uint8},(Ptr{Uint8},Int32,PtrSize),base,'\n',nread)
        if(pd!=C_NULL)
            #newline found - split buffer
            to=memio()
            ccall(:ios_splitbuf,Void,(Ptr{Void},Ptr{Void},Ptr{Uint8}),to,stream.buf.ios,pd)
            cb(stream,takebuf_array(string))
        end
    end
end

function success(cmd::Cmd)
    ptrs = _jl_pre_exec(cmd.exec)
    pp=Process(0,0,0,0)
    pp.handle=ccall(:jl_spawn, PtrSize, (Ptr{Uint8}, Ptr{Ptr{Uint8}}, Ptr{PtrSize}, Ptr{PtrSize}, Ptr{PtrSize},Ptr{PtrSize}),ptrs[1], ptrs, C_NULL, C_NULL,make_callback((args...)->end_process(pp)), C_NULL)
    run_event_loop()
    return (pp.exit_code==0)
end
run(cmd::Cmd)=success(cmd::Cmd)

function exec(thunk::Function)
    try
        thunk()
    catch e
        show(e)
        exit(0xff)
    end
    exit(0)
end

## process status ##

function _jl_pre_exec(args::Vector{ByteString})
    if length(args) < 1
        error("exec: too few words to exec")
    end
    ptrs = Array(Ptr{Uint8}, length(args)+1)
    for i = 1:length(args)
        ptrs[i] = args[i].data
    end
    ptrs[length(args)+1] = C_NULL
    return ptrs
end

## implementation of `cmd` syntax ##

arg_gen(x::String) = ByteString[x]

function arg_gen(head)
    if applicable(start,head)
        vals = ByteString[]
        for x in head
            push(vals,cstring(x))
        end
        return vals
    else
        return ByteString[cstring(head)]
    end
end

function arg_gen(head, tail...)
    head = arg_gen(head)
    tail = arg_gen(tail...)
    vals = ByteString[]
    for h = head, t = tail
        push(vals, cstring(strcat(h,t)))
    end
    vals
end

function cmd_gen(parsed)
    args = ByteString[]
    for arg in parsed
        append!(args, arg_gen(arg...))
    end
    Cmd(args)
end

macro cmd(str)
    :(cmd_gen($_jl_shell_parse(str)))
end

## low-level calls
print(b::ASCIIString) = write(current_output_stream(),b)

write(s::AsyncStream, b::ASCIIString) =
    ccall(:jl_puts, Int32, (Ptr{Uint8},PtrSize),b.data,int(s.handle))

write(s::AsyncStream, b::Uint8) =
    ccall(:jl_putc, Int32, (Uint8, PtrSize), b,s.handle)

write(s::AsyncStream, c::Char) =
    ccall(:jl_pututf8, Int32, (PtrSize,Char), s.handle,c)

write(c::Char) = write(current_output_stream(),c)

function write{T}(s::AsyncStream, a::Array{T})
    if isa(T,BitsKind)
        ccall(:jl_write, Uint,(Ptr{Void}, Ptr{Void}, Uint32),s.ios, a, uint(numel(a)*sizeof(T)))
    else
        invoke(write, (Any, Array), s, a)
    end
end

function write(s::AsyncStream, p::Ptr, nb::Integer)
    ccall(:jl_write, Uint,(PtrSize, Ptr{Void}, Uint),s.handle, p, uint(nb))
end

function _write(s::AsyncStream, p::PtrSize, nb::Integer)
    ccall(:jl_write, Uint,(PtrSize, PtrSize, Uint),s.handle,p,uint(nb))
end

(&)(left::Cmds,right::Cmd)  = (add(left.siblings,right);left)
(&)(left::Cmd,right::Cmds)  = right&left
function (&)(left::Cmds,right::Cmds)
    if(isa(left.pipeline,cmds))
        return (left.pipeline&right;left)
    end
    left.siblings=union(left.siblings,right.sigblings)
    left.pipeline=right.pipeline
    left
end
(&)(left::Cmd,right::Cmd)   = Cmds(left)&right

(|)(src::Cmds,dest::Cmds)   = (if(isa(src.pipeline,Cmds)); return (src.pipeline)|dest; else; src.pipeline=dest; return src; end)
(|)(src::Cmd,dest::Cmds)    = (s=Cmds(src);s.pipeline=dest;s)
(|)(src::Cmds,dest::Cmd)    = src|Cmds(dest)
(|)(src::Cmd,dest::Cmd)     = Cmds(src)|dest

function show(cmd::Cmd)
    if isa(cmd.exec,Vector{ByteString})
        esc = shell_escape(cmd.exec...)
        print('`')
        for c in esc
            if c == '`'
                print('\\')
            end
            print(c)
        end
        print('`')
    else
        invoke(show, (Any,), cmd.exec)
    end
end

function run(args...)
spawn(args...)
run_event_loop()
end
