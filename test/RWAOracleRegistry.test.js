const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("RWAOracleRegistry", function () {
  let registry;
  let admin;
  let guardian;
  let controller;
  let reporterOne;
  let reporterTwo;
  let outsider;
  let feedId;

  const metadataHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ipfs://rwa-metadata"));
  const evidenceHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ipfs://signed-evidence"));

  beforeEach(async function () {
    [admin, guardian, controller, reporterOne, reporterTwo, outsider] = await ethers.getSigners();
    const Registry = await ethers.getContractFactory("RWAOracleRegistry");
    registry = await Registry.deploy(admin.address, guardian.address);
    await registry.deployed();
    feedId = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MMC:RWA:HOUSE:123"));
    await registry.connect(controller).createFeed(feedId, {
      decimals: 2,
      quorum: 2,
      maxAge: 86400,
      maxDeviationBps: 2500,
      minValue: 1,
      maxValue: "1000000000000",
      metadataHash,
    });
    await registry.connect(controller).setReporter(feedId, reporterOne.address, true);
    await registry.connect(controller).setReporter(feedId, reporterTwo.address, true);
  });

  async function signedRound(overrides = {}) {
    const block = await ethers.provider.getBlock("latest");
    const report = {
      feedId,
      roundId: 1,
      value: 25000000,
      observedAt: block.timestamp,
      validUntil: block.timestamp + 3600,
      evidenceHash,
      ...overrides,
    };
    const domain = {
      name: "Oracle1 RWA Registry",
      version: "1",
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: registry.address,
    };
    const types = {
      Report: [
        { name: "feedId", type: "bytes32" },
        { name: "roundId", type: "uint64" },
        { name: "value", type: "int192" },
        { name: "observedAt", type: "uint64" },
        { name: "validUntil", type: "uint64" },
        { name: "evidenceHash", type: "bytes32" },
      ],
    };
    const signed = await Promise.all([reporterOne, reporterTwo].map(async (reporter) => ({
      reporter: reporter.address,
      signature: await reporter._signTypedData(domain, types, report),
    })));
    signed.sort((a, b) => a.reporter.toLowerCase().localeCompare(b.reporter.toLowerCase()));
    return { report, signed };
  }

  async function expectRevert(promise) {
    let reverted = false;
    try {
      await promise;
    } catch (error) {
      reverted = true;
    }
    expect(reverted).to.equal(true);
  }

  it("accepts a fresh round with a valid multi-attestor quorum", async function () {
    const { report, signed } = await signedRound();
    await expect(registry.connect(outsider).submitRound(report, signed))
      .to.emit(registry, "RoundAccepted");
    const latest = await registry.latestData(feedId);
    expect(latest.roundId).to.equal(1);
    expect(latest.value).to.equal(report.value);
    expect(latest.usable).to.equal(true);
    expect(latest.stale).to.equal(false);
  });

  it("rejects a report without quorum", async function () {
    const { report, signed } = await signedRound();
    await expectRevert(registry.submitRound(report, signed.slice(0, 1)));
  });

  it("rejects duplicate or unsorted reporters", async function () {
    const { report, signed } = await signedRound();
    await expectRevert(registry.submitRound(report, [signed[0], signed[0]]));
  });

  it("rejects stale reports", async function () {
    const block = await ethers.provider.getBlock("latest");
    const { report, signed } = await signedRound({
      observedAt: block.timestamp - 90000,
      validUntil: block.timestamp + 100,
    });
    await expectRevert(registry.submitRound(report, signed));
  });

  it("enforces deviation controls after the first accepted round", async function () {
    const first = await signedRound();
    await registry.submitRound(first.report, first.signed);
    const second = await signedRound({ roundId: 2, value: 50000000 });
    await expectRevert(registry.submitRound(second.report, second.signed));
  });

  it("rejects a signature made for a different registry domain", async function () {
    const { report, signed } = await signedRound();
    const Registry = await ethers.getContractFactory("RWAOracleRegistry");
    const otherRegistry = await Registry.deploy(admin.address, guardian.address);
    await otherRegistry.deployed();
    const domain = {
      name: "Oracle1 RWA Registry",
      version: "1",
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: otherRegistry.address,
    };
    const types = {
      Report: [
        { name: "feedId", type: "bytes32" },
        { name: "roundId", type: "uint64" },
        { name: "value", type: "int192" },
        { name: "observedAt", type: "uint64" },
        { name: "validUntil", type: "uint64" },
        { name: "evidenceHash", type: "bytes32" },
      ],
    };
    signed[0].signature = await reporterOne._signTypedData(domain, types, report);
    signed.sort((a, b) => a.reporter.toLowerCase().localeCompare(b.reporter.toLowerCase()));
    await expectRevert(registry.submitRound(report, signed));
  });

  it("rejects unauthorized reporters", async function () {
    const { report, signed } = await signedRound();
    const domain = {
      name: "Oracle1 RWA Registry",
      version: "1",
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: registry.address,
    };
    const types = {
      Report: [
        { name: "feedId", type: "bytes32" },
        { name: "roundId", type: "uint64" },
        { name: "value", type: "int192" },
        { name: "observedAt", type: "uint64" },
        { name: "validUntil", type: "uint64" },
        { name: "evidenceHash", type: "bytes32" },
      ],
    };
    signed[0] = {
      reporter: outsider.address,
      signature: await outsider._signTypedData(domain, types, report),
    };
    signed.sort((a, b) => a.reporter.toLowerCase().localeCompare(b.reporter.toLowerCase()));
    await expectRevert(registry.submitRound(report, signed));
  });

  it("prevents replaying or skipping round identifiers", async function () {
    const first = await signedRound();
    await registry.submitRound(first.report, first.signed);
    await expectRevert(registry.submitRound(first.report, first.signed));
    const skipped = await signedRound({ roundId: 3 });
    await expectRevert(registry.submitRound(skipped.report, skipped.signed));
  });

  it("enforces configured value bounds", async function () {
    const { report, signed } = await signedRound({ value: 0 });
    await expectRevert(registry.submitRound(report, signed));
  });

  it("marks accepted data stale after its configured maximum age", async function () {
    const { report, signed } = await signedRound();
    await registry.submitRound(report, signed);
    await ethers.provider.send("evm_increaseTime", [86401]);
    await ethers.provider.send("evm_mine");
    const latest = await registry.latestData(feedId);
    expect(latest.stale).to.equal(true);
    expect(latest.usable).to.equal(false);
  });

  it("allows the guardian to halt submissions and only the admin to resume", async function () {
    const { report, signed } = await signedRound();
    await registry.connect(guardian).pauseAll();
    await expectRevert(registry.connect(guardian).unpauseAll());
    await expectRevert(registry.submitRound(report, signed));
    await registry.connect(admin).unpauseAll();
    await expect(registry.submitRound(report, signed)).to.emit(registry, "RoundAccepted");
  });

  it("locks feed decimals after the first accepted round", async function () {
    const { report, signed } = await signedRound();
    await registry.submitRound(report, signed);
    await expectRevert(
      registry.connect(controller).updateFeedConfiguration(feedId, {
        decimals: 6,
        quorum: 2,
        maxAge: 86400,
        maxDeviationBps: 2500,
        minValue: 1,
        maxValue: "1000000000000",
        metadataHash,
      })
    );
  });

  it("pauses a disputed feed and records the guardian resolution", async function () {
    const { report, signed } = await signedRound();
    await registry.submitRound(report, signed);
    const reason = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("Appraisal challenged"));
    const resolution = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("Independent review complete"));
    await registry.connect(controller).openDispute(feedId, 1, reason);
    let latest = await registry.latestData(feedId);
    expect(latest.usable).to.equal(false);
    expect(latest.disputed).to.equal(true);
    await registry.connect(guardian).resolveDispute(feedId, true, resolution);
    const round = await registry.getRound(feedId, 1);
    expect(round.invalidated).to.equal(true);
    latest = await registry.latestData(feedId);
    expect(latest.usable).to.equal(false);
  });

  it("requires two-step feed-controller transfer", async function () {
    await registry.connect(controller).proposeController(feedId, outsider.address);
    await expect(registry.connect(outsider).acceptController(feedId))
      .to.emit(registry, "ControllerTransferred")
      .withArgs(feedId, controller.address, outsider.address);
    expect((await registry.getFeed(feedId)).controller).to.equal(outsider.address);
  });
});
