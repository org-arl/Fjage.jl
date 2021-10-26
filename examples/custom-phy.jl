using Fjage

### constants

const HDRSIZE = 5
const SAMPLES_PER_SYMBOL = 150
const NFREQ = 1/15
const MTU = 8

### import messages

const AgreeRsp = MessageClass(@__MODULE__, "org.arl.fjage.Message", nothing, Performative.AGREE)
const RefuseRsp = MessageClass(@__MODULE__, "org.arl.unet.RefuseRsp", nothing, Performative.REFUSE)
const DatagramReq = AbstractMessageClass(@__MODULE__, "org.arl.unet.DatagramReq")
const DatagramNtf = AbstractMessageClass(@__MODULE__, "org.arl.unet.DatagramNtf")
const ClearReq = MessageClass(@__MODULE__, "org.arl.unet.ClearReq")
const TxFrameReq = MessageClass(@__MODULE__, "org.arl.unet.phy.TxFrameReq", DatagramReq)
const TxRawFrameReq = MessageClass(@__MODULE__, "org.arl.unet.phy.TxRawFrameReq")
const TxFrameNtf = MessageClass(@__MODULE__, "org.arl.unet.phy.TxFrameNtf")
const RxFrameNtf = MessageClass(@__MODULE__, "org.arl.unet.phy.RxFrameNtf", DatagramNtf)
const BadFrameNtf = MessageClass(@__MODULE__, "org.arl.unet.phy.BadFrameNtf")
const GetPreambleSignalReq = MessageClass(@__MODULE__, "org.arl.unet.bb.GetPreambleSignalReq")
const TxBasebandSignalReq = MessageClass(@__MODULE__, "org.arl.unet.bb.TxBasebandSignalReq")
const RxBasebandSignalNtf = MessageClass(@__MODULE__, "org.arl.unet.bb.RxBasebandSignalNtf")

AgreeRsp(msg) = AgreeRsp(recipient=msg.sender, inReplyTo=msg.messageID)
RefuseRsp(msg, s=nothing) = RefuseRsp(recipient=msg.sender, inReplyTo=msg.messageID, reason=s)

### agent definition

@agent struct JuliaPhy
  bbsp::AgentID = AgentID("phy")
  pending::Dict{String,Message} = Dict{String,Message}()
end

function Fjage.setup(a::JuliaPhy)
  a.bbsp = agent(a, a.bbsp.name)
  register(a, "org.arl.unet.Services.DATAGRAM")
  register(a, "org.arl.unet.Services.PHYSICAL")
end

function Fjage.startup(a::JuliaPhy)
  subscribe(a, a.bbsp)
  nsamples = (MTU + HDRSIZE) * 8 * SAMPLES_PER_SYMBOL
  a.bbsp[1].modulation = "none"
  a.bbsp[1].basebandExtra = nsamples
  a.bbsp[1].basebandRx = true
  a.bbsp[2].modulation = "none"
  a.bbsp[2].basebandExtra = nsamples
  a.bbsp[2].basebandRx = true
end

### parameters

Fjage.params(::JuliaPhy) = [
  "org.arl.unet.DatagramParam.MTU" => :MTU,
  "org.arl.unet.DatagramParam.RTU" => :RTU,
  "org.arl.unet.phy.PhysicalParam.refPowerLevel" => :refPowerLevel,
  "org.arl.unet.phy.PhysicalParam.maxPowerLevel" => :maxPowerLevel,
  "org.arl.unet.phy.PhysicalParam.minPowerLevel" => :minPowerLevel,
  "org.arl.unet.phy.PhysicalParam.rxSensitivity" => :rxSensitivity,
  "org.arl.unet.phy.PhysicalParam.propagationSpeed" => :propagationSpeed,
  "org.arl.unet.phy.PhysicalParam.time" => :time,
  "org.arl.unet.phy.PhysicalParam.busy" => :busy,
  "org.arl.unet.phy.PhysicalParam.rxEnable" => :rxEnable
]

Fjage.get(a::JuliaPhy, ::Val{:title}) = "Julia PHY"
Fjage.get(a::JuliaPhy, ::Val{:description}) = "Custom PHY written as a Julia agent"
Fjage.get(a::JuliaPhy, ::Val{:MTU}) = MTU
Fjage.get(a::JuliaPhy, ::Val{:RTU}) = MTU
Fjage.get(a::JuliaPhy, ::Val{:refPowerLevel}) = a.bbsp.refPowerLevel
Fjage.get(a::JuliaPhy, ::Val{:maxPowerLevel}) = a.bbsp.maxPowerLevel
Fjage.get(a::JuliaPhy, ::Val{:minPowerLevel}) = a.bbsp.minPowerLevel
Fjage.get(a::JuliaPhy, ::Val{:rxSensitivity}) = a.bbsp.rxSensitivity
Fjage.get(a::JuliaPhy, ::Val{:propagationSpeed}) = a.bbsp.propagationSpeed
Fjage.get(a::JuliaPhy, ::Val{:time}) = a.bbsp.time
Fjage.get(a::JuliaPhy, ::Val{:busy}) = a.bbsp.busy
Fjage.get(a::JuliaPhy, ::Val{:rxEnable}) = a.bbsp.rxEnable

Fjage.params(::JuliaPhy, n::Int) = n == 1 || n == 2 ? [
  "org.arl.unet.DatagramParam.MTU" => :MTU,
  "org.arl.unet.DatagramParam.RTU" => :RTU,
  "org.arl.unet.phy.PhysicalChannelParam.frameLength" => :frameLength,
  "org.arl.unet.phy.PhysicalChannelParam.maxFrameLength" => :maxFrameLength,
  "org.arl.unet.phy.PhysicalChannelParam.fec" => :fec,
  "org.arl.unet.phy.PhysicalChannelParam.fecList" => :fecList,
  "org.arl.unet.phy.PhysicalChannelParam.errorDetection" => :errorDetection,
  "org.arl.unet.phy.PhysicalChannelParam.llr" => :llr,
  "org.arl.unet.phy.PhysicalChannelParam.powerLevel" => :powerLevel,
  "org.arl.unet.phy.PhysicalChannelParam.frameDuration" => :frameDuration,
  "org.arl.unet.phy.PhysicalChannelParam.dataRate" => :dataRate
] : Pair{String,Symbol}[]

Fjage.get(a::JuliaPhy, ::Val{:MTU}, ::Int) = MTU
Fjage.get(a::JuliaPhy, ::Val{:RTU}, ::Int) = MTU
Fjage.get(a::JuliaPhy, ::Val{:frameLength}, ::Int) = MTU + HDRSIZE
Fjage.get(a::JuliaPhy, ::Val{:maxFrameLength}, ::Int) = MTU + HDRSIZE
Fjage.get(a::JuliaPhy, ::Val{:fec}, ::Int) = 0
Fjage.get(a::JuliaPhy, ::Val{:fecList}, ::Int) = String[]
Fjage.get(a::JuliaPhy, ::Val{:errorDetection}, ::Int) = 8
Fjage.get(a::JuliaPhy, ::Val{:llr}, ::Int) = false
Fjage.get(a::JuliaPhy, ::Val{:powerLevel}, ::Int) = a.bbsp.signalPowerLevel
Fjage.set(a::JuliaPhy, ::Val{:powerLevel}, ::Int, v) = (a.bbsp.signalPowerLevel = v)
Fjage.get(a::JuliaPhy, ::Val{:dataRate}, ndx::Int) = 8 * Fjage.get(a, Val(:frameLength), ndx) / Fjage.get(a, Val(:frameDuration), ndx)

function Fjage.get(a::JuliaPhy, ::Val{:frameDuration}, ndx::Int)
  bbrate = a.bbsp.basebandRate
  pre = a.bbsp << GetPreambleSignalReq(preamble=ndx)
  (length(pre.signal) + (MTU + HDRSIZE) * 8 * SAMPLES_PER_SYMBOL) / bbrate
end

### process messages

function Fjage.processrequest(a::JuliaPhy, req::DatagramReq)
  data = something(req.data, UInt8[])
  length(data) > MTU && return RefuseRsp(req, "data exceeds MTU ($(length(data)) > $MTU)")
  ftype = something(req.type, 2)
  ftype ∈ [1,2] || return RefuseRsp(req, "invalid frame type ($ftype ∉ [1,2])")
  from = something(agentforservice(a, "org.arl.unet.Services.NODE_INFO").address, 0)
  buf = compose(from, something(req.to ,0), something(req.protocol, 0), data)
  transmit(a, ftype, buf, req) && return AgreeRsp(req)
  Message(req, Performative.FAILURE)
end

function Fjage.processrequest(a::JuliaPhy, req::TxRawFrameReq)
  data = something(req.data, UInt8[])
  length(data) != MTU + HDRSIZE && return RefuseRsp(req, "data length != frameLength ($(length(data)) != $(MTU+HDRSIZE))")
  ftype = something(req.type, 2)
  ftype ∈ [1,2] || return RefuseRsp(req, "invalid frame type ($ftype ∉ [1,2])")
  transmit(a, ftype, data, req) && return AgreeRsp(req)
  Message(req, Performative.FAILURE)
end

function Fjage.processrequest(a::JuliaPhy, req::ClearReq)
  empty!(a.pending)
  send(a.bbsp, ClearReq())
  AgreeRsp(req)
end

function Fjage.processmessage(a::JuliaPhy, msg::TxFrameNtf)
  msg.inReplyTo ∈ keys(a.pending) || return
  req = a.pending[msg.inReplyTo]
  delete!(a.pending, msg.inReplyTo)
  send(a, TxFrameNtf(
    recipient = req.sender,
    inReplyTo = req.messageID,
    type = msg.type,
    txTime = msg.txTime,
    location = msg.location
  ))
end

function Fjage.processmessage(a::JuliaPhy, msg::RxBasebandSignalNtf)
  nsamples = (MTU + HDRSIZE) * 8 * SAMPLES_PER_SYMBOL
  pdu = signal2bytes(msg.signal[end-nsamples+1:end])
  if length(pdu) > HDRSIZE && pdu[1] == foldl(xor, pdu[2:end]) && HDRSIZE + pdu[5] ≤ length(pdu)
    addr = something(agentforservice(a, "org.arl.unet.Services.NODE_INFO").address, 0)
    t = pdu[4] ∈ [0, addr] ? topic(AgentID(a)) : topic(AgentID(a), "snoop")
    send(a, RxFrameNtf(
      recipient = t,
      type = msg.preamble,
      rxTime = msg.rxTime,
      location = msg.location,
      rssi = msg.rssi,
      protocol = pdu[2],
      from = pdu[3],
      to = pdu[4],
      data = pdu[HDRSIZE+1:HDRSIZE+pdu[5]]
    ))
  else
    send(a, BadFrameNtf(
      recipient = topic(AgentID(a)),
      type = msg.preamble,
      rxTime = msg.rxTime,
      location = msg.location,
      rssi = msg.rssi,
      data = pdu
    ))
  end
end

### frame & signal processing

function compose(from, to, protocol, data)
  pdu = zeros(UInt8, HDRSIZE + MTU)
  pdu[2:HDRSIZE] .= (protocol, from, to, length(data))
  length(data) > 0 && (pdu[HDRSIZE+1:HDRSIZE+length(data)] .= data)
  pdu[1] = foldl(xor, pdu[2:end])
  pdu
end

function transmit(a, ftype, buf, req)
  sig = bytes2signal(buf)
  rsp = a.bbsp << TxBasebandSignalReq(preamble=ftype, signal=sig)
  rsp === nothing && return false
  rsp.performative == Performative.AGREE || return false
  a.pending[rsp.inReplyTo] = req
  true
end

function bytes2signal(buf)
  signal = Array{ComplexF32}(undef, length(buf) * 8 * SAMPLES_PER_SYMBOL)
  p = 1
  for b in buf
    for j in 0:7
      bit = (b >> j) & 0x01
      f = bit == 1 ? -NFREQ : NFREQ
      signal[p:p+SAMPLES_PER_SYMBOL-1] .= cis.(2pi * f * (0:SAMPLES_PER_SYMBOL-1))
      p += SAMPLES_PER_SYMBOL
    end
  end
  signal
end

function signal2bytes(signal)
  n = length(signal) ÷ (SAMPLES_PER_SYMBOL * 8)
  buf = zeros(Int8, n)
  p = 1
  for i in 1:length(buf)
    for j in 0:7
      s = @view signal[p:p+SAMPLES_PER_SYMBOL-1]
      p += SAMPLES_PER_SYMBOL
      x = cis.(2pi * NFREQ .* (0:SAMPLES_PER_SYMBOL-1))
      s0 = sum(s .* conj.(x))
      s1 = sum(s .* x)
      if abs(s1) > abs(s0)
        buf[i] = buf[i] | (0x01 << j)
      end
    end
  end
  buf
end
