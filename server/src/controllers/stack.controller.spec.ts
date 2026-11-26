import request from 'supertest';
import { StackController } from 'src/controllers/stack.controller.js';
import { StackService } from 'src/services/stack.service.js';
import { errorDto } from 'test/medium/responses.js';
import { factory } from 'test/small.factory.js';
import { ControllerContext, controllerSetup, mockBaseService } from 'test/utils.js';

describe(StackController.name, () => {
  let ctx: ControllerContext;
  const service = mockBaseService(StackService);

  beforeAll(async () => {
    ctx = await controllerSetup(StackController, [{ provide: StackService, useValue: service }]);
    return () => ctx.close();
  });

  beforeEach(() => {
    service.resetAllMocks();
    ctx.reset();
  });

  describe('POST /stacks', () => {
    it('should pass the non-merging option to stack creation', async () => {
      const assetIds = [factory.uuid(), factory.uuid()];
      const auth = factory.auth();
      ctx.authenticate.mockResolvedValue(auth);
      service.create.mockResolvedValue({ id: factory.uuid(), primaryAssetId: assetIds[0], assets: [] });

      const { status } = await request(ctx.getHttpServer()).post('/stacks').send({ assetIds, allowMerge: false });

      expect(status).toBe(201);
      expect(service.create).toHaveBeenCalledWith(auth, { assetIds, allowMerge: false });
    });

    it('should reject a non-boolean merge option', async () => {
      const { status } = await request(ctx.getHttpServer())
        .post('/stacks')
        .send({ assetIds: [factory.uuid(), factory.uuid()], allowMerge: 'false' });

      expect(status).toBe(400);
    });

    it('should require at least two assets', async () => {
      const { status, body } = await request(ctx.getHttpServer())
        .post('/stacks')
        .send({ assetIds: [factory.uuid()] });
      expect(status).toBe(400);
      expect(body).toEqual(
        errorDto.validationError([{ path: ['assetIds'], message: 'Too small: expected array to have >=2 items' }]),
      );
    });

    it('should require a valid id', async () => {
      const { status, body } = await request(ctx.getHttpServer())
        .post('/stacks')
        .send({ assetIds: ['invalid', 'invalid'] });
      expect(status).toBe(400);
      expect(body).toEqual(
        errorDto.validationError([
          { path: ['assetIds', 0], message: 'Invalid UUID' },
          { path: ['assetIds', 1], message: 'Invalid UUID' },
        ]),
      );
    });
  });
});
