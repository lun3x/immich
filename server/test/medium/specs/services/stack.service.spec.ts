import { BadRequestException, ConflictException } from '@nestjs/common';
import { Kysely } from 'kysely';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { EventRepository } from 'src/repositories/event.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { StackRepository } from 'src/repositories/stack.repository.js';
import { DB } from 'src/schema/index.js';
import { StackService } from 'src/services/stack.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { factory } from 'test/small.factory.js';
import { getKyselyDB } from 'test/utils.js';

let defaultDatabase: Kysely<DB>;

const setup = (db?: Kysely<DB>) => {
  return newMediumService(StackService, {
    database: db || defaultDatabase,
    real: [AccessRepository, AssetRepository, StackRepository],
    mock: [EventRepository, LoggingRepository],
  });
};

const createPair = async () => {
  const { sut, ctx } = setup();
  ctx.getMock(EventRepository).emit.mockResolvedValue();
  const { user } = await ctx.newUser();
  const { asset: jpeg } = await ctx.newAsset({ ownerId: user.id, originalFileName: 'photo.jpg' });
  const { asset: raw } = await ctx.newAsset({ ownerId: user.id, originalFileName: 'photo.raf' });
  const auth = factory.auth({ user });
  const create = () => sut.create(auth, { assetIds: [jpeg.id, raw.id], allowMerge: false });
  const rows = () =>
    ctx.database.selectFrom('asset').select(['id', 'stackId']).where('ownerId', '=', user.id).orderBy('id').execute();
  return { sut, ctx, user, jpeg, raw, auth, create, rows };
};

beforeAll(async () => {
  defaultDatabase = await getKyselyDB();
});

describe(StackService.name, () => {
  describe('non-merging creation', () => {
    it('creates exactly the pair with JPEG primary before metadata extraction', async () => {
      const { ctx, jpeg, raw, create, rows } = await createPair();
      const result = await create();

      expect(result.primaryAssetId).toBe(jpeg.id);
      expect(result.assets.map(({ id }) => id).sort()).toEqual([jpeg.id, raw.id].sort());
      const memberships = await rows();
      expect(memberships.every(({ stackId }) => stackId === result.id)).toBe(true);
      expect(ctx.getMock(EventRepository).emit).toHaveBeenCalledTimes(1);
    });

    it('returns an existing common stack without changing its primary or members', async () => {
      const { ctx, user, jpeg, raw, create } = await createPair();
      const { asset: other } = await ctx.newAsset({ ownerId: user.id });
      const { stack } = await ctx.newStack({ ownerId: user.id }, [raw.id, jpeg.id, other.id]);
      const result = await create();

      expect(result.id).toBe(stack.id);
      expect(result.primaryAssetId).toBe(raw.id);
      expect(result.assets.map(({ id }) => id).sort()).toEqual([raw.id, jpeg.id, other.id].sort());
      expect(ctx.getMock(EventRepository).emit).not.toHaveBeenCalled();
    });

    it('does not merge an existing stack containing the JPEG', async () => {
      const { ctx, user, jpeg, create, rows } = await createPair();
      const { asset: other } = await ctx.newAsset({ ownerId: user.id });
      const { stack } = await ctx.newStack({ ownerId: user.id }, [jpeg.id, other.id]);
      const before = await rows();

      await expect(create()).rejects.toBeInstanceOf(ConflictException);
      expect(await rows()).toEqual(before);
      expect(await ctx.database.selectFrom('stack').select('id').where('ownerId', '=', user.id).execute()).toEqual([
        { id: stack.id },
      ]);
    });

    it('does not pull a RAW child out of another stack', async () => {
      const { ctx, user, raw, create, rows } = await createPair();
      const { asset: other } = await ctx.newAsset({ ownerId: user.id });
      await ctx.newStack({ ownerId: user.id }, [other.id, raw.id]);
      const before = await rows();

      await expect(create()).rejects.toBeInstanceOf(ConflictException);
      expect(await rows()).toEqual(before);
    });

    it('does not merge two existing stacks', async () => {
      const { ctx, user, jpeg, raw, create, rows } = await createPair();
      for (const component of [jpeg, raw]) {
        const { asset } = await ctx.newAsset({ ownerId: user.id });
        await ctx.newStack({ ownerId: user.id }, [component.id, asset.id]);
      }
      const before = await rows();

      await expect(create()).rejects.toBeInstanceOf(ConflictException);
      expect(await rows()).toEqual(before);
    });

    it('does not stack a trashed component', async () => {
      const { ctx, raw, create, rows } = await createPair();
      await ctx.database.updateTable('asset').set({ deletedAt: new Date() }).where('id', '=', raw.id).execute();

      await expect(create()).rejects.toBeInstanceOf(ConflictException);
      const memberships = await rows();
      expect(memberships.every(({ stackId }) => stackId === null)).toBe(true);
    });

    it('requires two distinct assets', async () => {
      const { sut, auth, jpeg } = await createPair();
      await expect(sut.create(auth, { assetIds: [jpeg.id, jpeg.id], allowMerge: false })).rejects.toBeInstanceOf(
        BadRequestException,
      );
    });

    it('serializes competing requests sharing an asset', async () => {
      const { sut, ctx, user, jpeg, raw, auth, create, rows } = await createPair();
      const { asset: other } = await ctx.newAsset({ ownerId: user.id });
      const results = await Promise.allSettled([
        create(),
        sut.create(auth, { assetIds: [jpeg.id, other.id], allowMerge: false }),
      ]);

      expect(results.filter(({ status }) => status === 'fulfilled')).toHaveLength(1);
      expect(results.filter(({ status }) => status === 'rejected')).toHaveLength(1);
      const memberships = await rows();
      const pairedIds = memberships.filter(({ stackId }) => stackId !== null).map(({ id }) => id);
      expect(pairedIds).toHaveLength(2);
      expect(pairedIds).toContain(jpeg.id);
      expect(pairedIds.includes(raw.id) !== pairedIds.includes(other.id)).toBe(true);
    });

    it('reuses the result of duplicate concurrent pair requests', async () => {
      const { create } = await createPair();
      const [first, second] = await Promise.all([create(), create()]);
      expect(first.id).toBe(second.id);
    });

    it('checks membership after a competing write commits', async () => {
      const { ctx, user, jpeg, raw, create } = await createPair();
      const { asset: other } = await ctx.newAsset({ ownerId: user.id });
      const { asset: sibling } = await ctx.newAsset({ ownerId: user.id });
      const { stack } = await ctx.newStack({ ownerId: user.id }, [other.id, sibling.id]);
      const gate = Promise.withResolvers<void>();
      const locked = Promise.withResolvers<void>();
      const writer = ctx.database.transaction().execute(async (tx) => {
        await tx.selectFrom('asset').select('id').where('id', '=', jpeg.id).forUpdate().execute();
        locked.resolve();
        await gate.promise;
        await tx.updateTable('asset').set({ stackId: stack.id }).where('id', '=', jpeg.id).execute();
      });
      await locked.promise;
      const pending = create();
      gate.resolve();
      await writer;

      await expect(pending).rejects.toBeInstanceOf(ConflictException);
      const remaining = await ctx.database
        .selectFrom('asset')
        .select('stackId')
        .where('id', '=', raw.id)
        .executeTakeFirstOrThrow();
      expect(remaining.stackId).toBeNull();
      const unchanged = await ctx.database
        .selectFrom('stack')
        .select('primaryAssetId')
        .where('id', '=', stack.id)
        .executeTakeFirstOrThrow();
      expect(unchanged.primaryAssetId).toBe(other.id);
    });

    it('keeps ordinary merging available for explicit stack actions', async () => {
      const { sut, ctx, user, jpeg, raw, auth } = await createPair();
      const { asset: other } = await ctx.newAsset({ ownerId: user.id });
      await ctx.newStack({ ownerId: user.id }, [jpeg.id, other.id]);
      const result = await sut.create(auth, { assetIds: [jpeg.id, raw.id] });
      const members = await ctx.database.selectFrom('asset').select('id').where('stackId', '=', result.id).execute();
      expect(members.map(({ id }) => id).sort()).toEqual([jpeg.id, raw.id, other.id].sort());
    });
  });

  describe('create', () => {
    it('should not stack an asset of another user', async () => {
      const { sut, ctx } = setup();
      const { user } = await ctx.newUser();
      const { user: otherUser } = await ctx.newUser();
      const { asset } = await ctx.newAsset({ ownerId: user.id });
      const { asset: otherAsset } = await ctx.newAsset({ ownerId: otherUser.id });

      await expect(sut.create(factory.auth({ user }), { assetIds: [asset.id, otherAsset.id] })).rejects.toThrow(
        'Not found or no asset.update access',
      );
      await expect(
        ctx.database.selectFrom('stack').selectAll().where('ownerId', '=', user.id).execute(),
      ).resolves.toEqual([]);
    });
  });
});
