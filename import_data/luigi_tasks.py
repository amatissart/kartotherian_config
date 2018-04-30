import os.path
import luigi
import requests
import invoke
from invoke import Context, Config
from datetime import datetime, timedelta

import tasks as invoke_tasks


class InvokeContext:
    @classmethod
    def get(cls):
        conf = Config(project_location='.')
        conf.load_project()
        return Context(conf)


class importOsmConfig(luigi.Config):
    import_id = luigi.Parameter()
    pbf_url = luigi.Parameter()
    osm_file = luigi.Parameter()


class ImportPipelineTask(luigi.Task):
    def __init__(self, *args, **kwargs):
        self.config = importOsmConfig()
        super().__init__(*args, **kwargs)

    def output(self):
        return luigi.LocalTarget(
            path='/tmp/import_pipeline/{import_id}/{task_name}.done'.format(
                import_id=self.config.import_id,
                task_name=self.task_id
            )
        )

    def invoke_task_and_write_output(self, task_name, ctx=None):
        if ctx is None:
            ctx = InvokeContext.get()
        getattr(invoke_tasks, task_name)(ctx)
        with self.output().open('w') as output:
            output.write('')


###############################################################
# Pipeline Tasks

class DownloadPbfTask(ImportPipelineTask):
    osm_file = luigi.Parameter()
    force = luigi.BoolParameter(default=False)

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        if self.force:
            output = self.output()
            if output.exists():
                output.move(f'{output.path}.bak')

    def run(self):
        invoke.run(f'wget {self.config.pbf_url} -O {self.osm_file}')

    def output(self):
        return luigi.LocalTarget(path=self.osm_file)

    def complete(self):
        """
        Download is 'complete' if the pbf file exists and is
        up-to-date compared to the server file (with 2-days tolerance)
        """
        if not self.output().exists():
            return False
        file_mtime = datetime.utcfromtimestamp(
            os.path.getmtime(self.output().path)
        )
        server_head = requests.head(self.config.pbf_url)
        server_last_modified = server_head.headers.get('Last-Modified')

        if server_last_modified is None:
            # Server does not return "Last-Modified" date
            # Let's assume the file is up-to-date
            # (that prevents dependencies error)
            return True

        server_mtime = datetime.strptime(
            server_last_modified,
            '%a, %d %b %Y %H:%M:%S %Z'
        )
        return server_mtime - file_mtime < timedelta(days=2)


class LoadBaseMapTask(ImportPipelineTask):
    def requires(self):
        yield DownloadPbfTask(osm_file=self.config.osm_file)

    def run(self):
        invoke_context = InvokeContext.get()
        invoke_context.osm_file = self.config.osm_file
        self.invoke_task_and_write_output('load_basemap', ctx=invoke_context)


class LoadPoiTask(ImportPipelineTask):
    def requires(self):
        yield DownloadPbfTask(osm_file=self.config.osm_file)

    def run(self):
        invoke_context = InvokeContext.get()
        invoke_context.osm_file = self.config.osm_file
        self.invoke_task_and_write_output('load_poi', ctx=invoke_context)


class LoadOmtSqlTask(ImportPipelineTask):
    def requires(self):
        yield LoadBaseMapTask()
        yield LoadPoiTask()

    def run(self):
        self.invoke_task_and_write_output('run_sql_script')


class LoadNaturalEarthTask(ImportPipelineTask):
    def run(self):
        self.invoke_task_and_write_output('import_natural_earth')


class LoadWaterTask(ImportPipelineTask):
    def run(self):
        self.invoke_task_and_write_output('import_water_polygon')


class LoadLakeTask(ImportPipelineTask):
    def run(self):
        self.invoke_task_and_write_output('import_lake')


class LoadBorderTask(ImportPipelineTask):
    def run(self):
        self.invoke_task_and_write_output('import_border')


class PostSqlTask(ImportPipelineTask):
    def requires(self):
        yield LoadOmtSqlTask()
        yield LoadNaturalEarthTask()
        yield LoadWaterTask()
        yield LoadLakeTask()
        yield LoadBorderTask()

    def run(self):
        self.invoke_task_and_write_output('run_post_sql_scripts')


class InitialImport(luigi.WrapperTask):
    def requires(self):
        yield PostSqlTask()


class GenerateTiles(ImportPipelineTask):
    tilerator_url = luigi.Parameter()
    zoom = luigi.OptionalParameter(default=None)
    tile_x = luigi.IntParameter(default=0)
    tile_y = luigi.IntParameter(default=0)
    parts = luigi.IntParameter(default=80)

    def requires(self):
        yield InitialImport()

    def post_tilerator_jobs(self, params):
        resp = requests.post(
            url=f'{self.tilerator_url}/add',
            params=params
        )
        resp.raise_for_status()

    def run(self):
        print('Create tiles jobs....')
        basemap_query = {
            'generatorId': 'substbasemap',
            'storageId': 'basemap',
            'fromZoom': 0,
            'beforeZoom': 15,
            'keepJob': 'true',
            'deleteEmpty':'true',
            'parts': self.parts,
        }
        poi_query = {
            'generatorId': 'gen_poi',
            'storageId': 'poi',
            'fromZoom': 14,
            'beforeZoom': 15,
            'keepJob': 'true',
            'deleteEmpty':'true',
            'parts': self.parts,
        }
        if self.zoom is not None:
            for q in [basemap_query, poi_query]:
                q['zoom'] = self.zoom
                q['x'] = self.tile_x
                q['y'] = self.tile_y

        self.post_tilerator_jobs(params=basemap_query)
        self.post_tilerator_jobs(params=poi_query)

        with self.output().open('w') as output:
            output.write('')
