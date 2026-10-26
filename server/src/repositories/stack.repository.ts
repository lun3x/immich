import { Injectable } from '@nestjs/common';
import { jsonArrayFrom, jsonObjectFrom } from 'kysely/helpers/postgres';
import { InjectKysely } from 'nestjs-kysely';
import type { ExpressionBuilder, Insertable, Kysely, Updateable } from 'kysely';
import { Stack, columns } from 'src/database.js';
import { DummyValue, GenerateSql } from 'src/decorators.js';
import { DB } from 'src/schema/index.js';
import { StackTable } from 'src/schema/tables/stack.table.js';
import { asUuid, withDefaultVisibility } from 'src/utils/database.js';

export interface StackSearch {
  ownerId: string;
  primaryAssetId?: string;
}

type NonMergingStackResult = { status: 'created' | 'existing'; stack: Stack } | { status: 'conflict' };

const withAssets = (eb: ExpressionBuilder<DB, 'stack'>, withTags = false) => {
  return jsonArrayFrom(
    eb
      .selectFrom('asset')
      .selectAll('asset')
      .innerJoinLateral(
        (eb) =>
          eb
            .selectFrom('asset_exif')
            .select(columns.exif)
            .whereRef('asset_exif.assetId', '=', 'asset.id')
            .as('exifInfo'),
        (join) => join.onTrue(),
      )
      .$if(withTags, (eb) =>
        eb.select((eb) =>
          jsonArrayFrom(
            eb
              .selectFrom('tag')
              .select(columns.tag)
              .innerJoin('tag_asset', 'tag.id', 'tag_asset.tagId')
              .whereRef('tag_asset.assetId', '=', 'asset.id'),
          ).as('tags'),
        ),
      )
      .select((eb) => eb.fn.toJson('exifInfo').as('exifInfo'))
      .where('asset.deletedAt', 'is', null)
      .whereRef('asset.stackId', '=', 'stack.id')
      .$call(withDefaultVisibility)
      .orderBy('asset.fileCreatedAt', 'asc'),
  ).as('assets');
};

@Injectable()
export class StackRepository {
  constructor(@InjectKysely() private db: Kysely<DB>) {}

  async createWithoutMerging(
    entity: Omit<Insertable<StackTable>, 'primaryAssetId'>,
    assetIds: [string, string],
  ): Promise<NonMergingStackResult> {
    return this.db.transaction().execute(async (tx) => {
      // Lock in a consistent order, then inspect the committed memberships. No
      // existing stack is deleted or expanded by this path.
      const assets = await tx
        .selectFrom('asset')
        .select(['id', 'ownerId', 'deletedAt', 'stackId'])
        .where('id', 'in', assetIds)
        .orderBy('id')
        .forUpdate()
        .execute();

      if (assets.length !== 2 || assets.some((asset) => asset.ownerId !== entity.ownerId || asset.deletedAt)) {
        return { status: 'conflict' };
      }

      let stackId = assets[0].stackId;
      let status: 'created' | 'existing' = 'existing';
      if (stackId || assets[1].stackId) {
        if (!stackId || stackId !== assets[1].stackId) {
          return { status: 'conflict' };
        }
      } else {
        const created = await tx
          .insertInto('stack')
          .values({ ...entity, primaryAssetId: assetIds[0] })
          .returning('id')
          .executeTakeFirstOrThrow();
        stackId = created.id;
        status = 'created';
        await tx.updateTable('asset').set({ stackId }).where('id', 'in', assetIds).execute();
      }

      // Metadata extraction can lag behind upload. Unlike an inner lateral join,
      // a nullable EXIF object keeps both newly uploaded originals in the response.
      const stack = await tx
        .selectFrom('stack')
        .selectAll('stack')
        .select((eb) =>
          jsonArrayFrom(
            eb
              .selectFrom('asset')
              .selectAll('asset')
              .select((eb) =>
                jsonObjectFrom(
                  eb.selectFrom('asset_exif').select(columns.exif).whereRef('asset_exif.assetId', '=', 'asset.id'),
                ).as('exifInfo'),
              )
              .whereRef('asset.stackId', '=', 'stack.id')
              .where('asset.deletedAt', 'is', null)
              .$call(withDefaultVisibility)
              .orderBy('asset.fileCreatedAt', 'asc'),
          ).as('assets'),
        )
        .where('stack.id', '=', stackId)
        .where('stack.ownerId', '=', entity.ownerId)
        .executeTakeFirst();

      if (!stack) {
        return { status: 'conflict' };
      }

      return { status, stack };
    });
  }

  @GenerateSql({ params: [{ ownerId: DummyValue.UUID }] })
  search(query: StackSearch) {
    return this.db
      .selectFrom('stack')
      .selectAll('stack')
      .select(withAssets)
      .where('stack.ownerId', '=', query.ownerId)
      .$if(!!query.primaryAssetId, (eb) => eb.where('stack.primaryAssetId', '=', query.primaryAssetId!))
      .execute();
  }

  async create(entity: Omit<Insertable<StackTable>, 'primaryAssetId'>, assetIds: string[]) {
    return this.db.transaction().execute(async (tx) => {
      const stacks = await tx
        .selectFrom('stack')
        .where('stack.ownerId', '=', entity.ownerId)
        .where('stack.primaryAssetId', 'in', assetIds)
        .select('stack.id')
        .select((eb) =>
          jsonArrayFrom(
            eb
              .selectFrom('asset')
              .select('asset.id')
              .whereRef('asset.stackId', '=', 'stack.id')
              .where('asset.deletedAt', 'is', null),
          ).as('assets'),
        )
        .execute();

      const uniqueIds = new Set<string>(assetIds);

      // children
      for (const stack of stacks) {
        if (stack.assets && stack.assets.length > 0) {
          for (const asset of stack.assets) {
            uniqueIds.add(asset.id);
          }
        }
      }

      if (stacks.length > 0) {
        await tx
          .deleteFrom('stack')
          .where(
            'id',
            'in',
            stacks.map((stack) => stack.id),
          )
          .execute();
      }

      const newRecord = await tx
        .insertInto('stack')
        .values({ ...entity, primaryAssetId: assetIds[0] })
        .returning('id')
        .executeTakeFirstOrThrow();

      await tx
        .updateTable('asset')
        .set({
          stackId: newRecord.id,
          updatedAt: new Date(),
        })
        .where('id', 'in', [...uniqueIds])
        .execute();

      return tx
        .selectFrom('stack')
        .selectAll('stack')
        .select(withAssets)
        .where('id', '=', newRecord.id)
        .executeTakeFirstOrThrow();
    });
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  async delete(id: string): Promise<void> {
    await this.db.deleteFrom('stack').where('id', '=', asUuid(id)).execute();
  }

  async deleteAll(ids: string[]): Promise<void> {
    await this.db.deleteFrom('stack').where('id', 'in', ids).execute();
  }

  update(id: string, entity: Updateable<StackTable>) {
    return this.db
      .updateTable('stack')
      .set(entity)
      .where('id', '=', asUuid(id))
      .returningAll('stack')
      .returning((eb) => withAssets(eb, true))
      .executeTakeFirstOrThrow();
  }

  @GenerateSql({ params: [DummyValue.UUID] })
  getById(id: string) {
    return this.db
      .selectFrom('stack')
      .selectAll()
      .select((eb) => withAssets(eb, true))
      .where('id', '=', asUuid(id))
      .executeTakeFirst();
  }

  @GenerateSql({ params: [DummyValue.UUID, DummyValue.UUID] })
  getForAssetRemoval(assetId: string) {
    return this.db
      .selectFrom('asset')
      .leftJoin('stack', 'stack.id', 'asset.stackId')
      .select(['stackId as id', 'stack.primaryAssetId'])
      .where('asset.id', '=', assetId)
      .executeTakeFirst();
  }

  @GenerateSql({ params: [{ sourceId: DummyValue.UUID, targetId: DummyValue.UUID }] })
  merge({ sourceId, targetId }: { sourceId: string; targetId: string }) {
    return this.db.updateTable('asset').set({ stackId: targetId }).where('asset.stackId', '=', sourceId).execute();
  }
}
