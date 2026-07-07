package org.arl.fjage.stress;

import java.util.BitSet;
import java.util.HashMap;
import java.util.Map;
import java.util.Random;

import org.arl.fjage.Agent;
import org.arl.fjage.Message;
import org.arl.fjage.MessageBehavior;
import org.arl.fjage.Performative;
import org.arl.fjage.PoissonBehavior;

/**
 * Java participant in the container stress test. Message-controlled via StressCtl
 * (start/stop/stats) so one binary serves all stress levels. Keeps the same
 * sent/received ledger as the Julia StressAgent.
 */
public class JStressAgent extends Agent {

  long bcastSent = 0;
  Map<String,Long> dmSent = new HashMap<String,Long>();
  Map<String,BitSet> seen = new HashMap<String,BitSet>();
  long dups = 0;
  long latN = 0, latSum = 0, latMin = Long.MAX_VALUE, latMax = 0;
  long latFrom = Long.MAX_VALUE;
  String[] peers = new String[0];
  double rate = 1.0;
  PoissonBehavior sender = null;
  PoissonBehavior churner = null;
  java.util.List<PoissonBehavior> secondaries = new java.util.ArrayList<PoissonBehavior>();
  Random rnd = new Random();

  static final double CHURN_TARGET = 3.0;
  static final int CHURN_MAX = 6;

  void sendStress() {
    StressMsg m = new StressMsg();
    if (rnd.nextBoolean()) {
      m.stream = "b";
      m.seq = ++bcastSent;
      m.setRecipient(topic("stress"));
    } else {
      String p = peers[rnd.nextInt(peers.length)];
      long n = dmSent.merge(p, 1L, Long::sum);
      m.stream = "d";
      m.seq = n;
      m.setRecipient(agent(p));
    }
    m.t0 = currentTimeMillis();
    send(m);
  }

  PoissonBehavior newSecondary() {
    long millis = Math.max(1, Math.round(1000.0 * CHURN_TARGET / rate));
    return new PoissonBehavior(millis) {
      @Override
      public void onTick() {
        sendStress();
      }
    };
  }

  @Override
  protected void init() {
    subscribe(topic("stress"));
    add(new MessageBehavior() {
      @Override
      public void onReceive(Message msg) {
        if (msg instanceof StressCtl) handleCtl((StressCtl)msg);
        else if (msg instanceof StressMsg) handleStress((StressMsg)msg);
      }
    });
  }

  void handleCtl(StressCtl ctl) {
    if ("start".equals(ctl.cmd)) {
      if (sender == null && churner == null) {  // idempotent: control requests may be retried
        peers = ctl.peers;
        rate = ctl.rate;
        latFrom = currentTimeMillis() + ctl.warmup;
        if (ctl.churn) {
          // primary behavior only churns; secondaries generate the traffic
          churner = new PoissonBehavior(500) {
            @Override
            public void onTick() {
              if (secondaries.isEmpty() || (rnd.nextBoolean() && secondaries.size() < CHURN_MAX)) {
                PoissonBehavior sb = newSecondary();
                secondaries.add(sb);
                add(sb);
              } else {
                secondaries.remove(rnd.nextInt(secondaries.size())).stop();
              }
            }
          };
          add(churner);
        } else {
          long millis = Math.max(1, Math.round(1000.0 / ctl.rate));
          sender = new PoissonBehavior(millis) {
            @Override
            public void onTick() {
              sendStress();
            }
          };
          add(sender);
        }
      }
      send(new Message(ctl, Performative.AGREE));
    } else if ("stop".equals(ctl.cmd)) {
      if (sender != null) {
        sender.stop();
        sender = null;
      }
      if (churner != null) {
        churner.stop();
        churner = null;
      }
      for (PoissonBehavior sb : secondaries) sb.stop();
      secondaries.clear();
      send(new Message(ctl, Performative.AGREE));
    } else if ("stats".equals(ctl.cmd)) {
      StressStats s = new StressStats(ctl);
      s.bcastSent = bcastSent;
      s.dmPeers = peers;
      s.dmSent = new long[peers.length];
      s.senders = peers;
      s.recvBcast = new long[peers.length];
      s.recvDm = new long[peers.length];
      for (int i = 0; i < peers.length; i++) {
        Long d = dmSent.get(peers[i]);
        s.dmSent[i] = d == null ? 0 : d;
        BitSet b = seen.get(peers[i]+"/b");
        s.recvBcast[i] = b == null ? 0 : b.cardinality();
        BitSet d2 = seen.get(peers[i]+"/d");
        s.recvDm[i] = d2 == null ? 0 : d2.cardinality();
      }
      s.dups = dups;
      s.latN = latN;
      s.latSum = latSum;
      s.latMin = latN == 0 ? 0 : latMin;
      s.latMax = latMax;
      send(s);
    }
  }

  void handleStress(StressMsg m) {
    String from = m.getSender() == null ? "?" : m.getSender().getName();
    if (from.equals(getName())) return;   // own topic broadcasts come back; ignore
    String key = from + "/" + ("d".equals(m.stream) ? "d" : "b");
    BitSet bs = seen.get(key);
    if (bs == null) {
      bs = new BitSet();
      seen.put(key, bs);
    }
    int q = (int)m.seq;
    if (bs.get(q)) dups++;
    else {
      bs.set(q);
      if (m.t0 >= latFrom) {
        long lat = currentTimeMillis() - m.t0;
        latN++;
        latSum += lat;
        if (lat < latMin) latMin = lat;
        if (lat > latMax) latMax = lat;
      }
    }
  }
}
